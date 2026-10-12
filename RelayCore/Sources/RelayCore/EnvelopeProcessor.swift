//
//  EnvelopeProcessor.swift
//  RelayCore
//
//  The incoming pipeline shared by the app (WebSocket) and the NSE (push).
//  It claims an envelope exactly once, decrypts it against the shared store,
//  applies the content, and reports what happened. Network side effects
//  (receipts, group re-sync) are returned rather than performed, so the NSE
//  can skip them.
//

import CryptoCore
import Foundation
import LibSignalClient
import OSLog
import RelayKit
import SecureStorage
import SwiftProtobuf

/// A poll as stored in the message body after the `__poll__:` prefix.
public struct PollPayload: Codable, Sendable {
    public let question: String
    public let options: [String]
    public let multiSelect: Bool

    public init(question: String, options: [String], multiSelect: Bool) {
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
    }

    public func encode() -> String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func decode(_ json: String) -> PollPayload? {
        json.data(using: .utf8).flatMap { try? JSONDecoder().decode(PollPayload.self, from: $0) }
    }
}

/// Actions the caller may perform after processing. The NSE ignores these.
public struct EnvelopeSideEffects: Sendable {
    public var deliveryReceiptTimestamp: Int64?

    public init(deliveryReceiptTimestamp: Int64? = nil) {
        self.deliveryReceiptTimestamp = deliveryReceiptTimestamp
    }
}

/// A user-visible message to surface as a notification.
public struct NotificationContent: Sendable {
    public let senderAccount: String
    public let conversationId: String
    public let body: String
    /// The stored message this announces, so an unsend, edit or expiry can
    /// remove just its notification. Empty when it isn't one message.
    public var messageId: String = ""
}

public enum GroupAction: Sendable, Codable {
    case create, add, remove, leave, rename, describe, avatar
    case promoteAdmin, demoteAdmin, setAnnounceOnly, setScreenSecurity
    case unknown
}

/// A group membership or metadata change. `members` carries the full roster
/// on CREATE/ADD/REMOVE/LEAVE so recipients stay current without asking
/// the server.
public struct GroupUpdateInfo: Sendable, Codable {
    public let groupId: String
    public let action: GroupAction
    public let actor: String
    public let target: String
    public let name: String
    public let description: String
    public let avatarId: String
    public let avatarKey: Data
    public let avatarDigest: Data
    public let members: [String]
    public let admins: [String]
    public let announceOnly: Bool
    /// Group screenshot-hide state for SET_SCREEN_SECURITY.
    public let screenSecurity: Bool
    public let revision: Int64
    /// The group's sender-key epoch after this change; empty if unchanged.
    public let distributionId: String
    /// Group invite capability; empty if none or unchanged.
    public let inviteKey: Data

    public init(
        groupId: String, action: GroupAction, actor: String, target: String, name: String,
        description: String = "", avatarId: String = "", avatarKey: Data = Data(), avatarDigest: Data = Data(),
        members: [String] = [], admins: [String] = [], announceOnly: Bool = false,
        screenSecurity: Bool = false, revision: Int64 = 0,
        distributionId: String = "", inviteKey: Data = Data()
    ) {
        self.groupId = groupId
        self.action = action
        self.actor = actor
        self.target = target
        self.name = name
        self.description = description
        self.avatarId = avatarId
        self.avatarKey = avatarKey
        self.avatarDigest = avatarDigest
        self.members = members
        self.admins = admins
        self.announceOnly = announceOnly
        self.screenSecurity = screenSecurity
        self.revision = revision
        self.distributionId = distributionId
        self.inviteKey = inviteKey
    }
}

/// The sender took a screenshot (sent whatever the hide setting). The caller
/// shows an in-chat notice.
public struct ScreenshotAlertInfo: Sendable, Codable {
    public let conversationId: String
    public let senderAccount: String
    public let timestamp: Int64
    public init(conversationId: String, senderAccount: String, timestamp: Int64) {
        self.conversationId = conversationId
        self.senderAccount = senderAccount
        self.timestamp = timestamp
    }
}

/// A 1:1 peer's screenshot-hide preference: the peer's side of the OR that
/// decides effective hiding.
public struct ScreenSecurityInfo: Sendable, Codable {
    public let conversationId: String
    public let senderAccount: String
    public let enabled: Bool
    public let timestamp: Int64
    public init(conversationId: String, senderAccount: String, enabled: Bool, timestamp: Int64) {
        self.conversationId = conversationId
        self.senderAccount = senderAccount
        self.enabled = enabled
        self.timestamp = timestamp
    }
}

public struct PollInfo: Sendable {
    public let question: String
    public let options: [String]
    public let multiSelect: Bool
    public let timestamp: Int64
    public let conversationId: String
    public let author: String

    public init(question: String, options: [String], multiSelect: Bool, timestamp: Int64, conversationId: String, author: String) {
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
        self.timestamp = timestamp
        self.conversationId = conversationId
        self.author = author
    }
}

public struct PollVoteInfo: Sendable {
    public let pollAuthor: String
    public let pollTimestamp: Int64
    public let selectedOptions: [Int]
    public let timestamp: Int64
    public let conversationId: String
    public let voterAccount: String

    public init(pollAuthor: String, pollTimestamp: Int64, selectedOptions: [Int], timestamp: Int64, conversationId: String, voterAccount: String) {
        self.pollAuthor = pollAuthor
        self.pollTimestamp = pollTimestamp
        self.selectedOptions = selectedOptions
        self.timestamp = timestamp
        self.conversationId = conversationId
        self.voterAccount = voterAccount
    }
}

/// A call signalling message, routed by the caller to CallManager.
public struct CallInfo: Sendable {
    public enum CallType: Sendable, Codable {
        case offer, answer, ice, hangup, busy, ringing
        case groupRing, groupJoin, groupLeave
        case linkJoinRequest, linkAdmit, linkRoster, linkDeny
    }
    public let callId: String
    public let type: CallType
    public let sdp: String
    public let ice: String
    public let callerAccount: String
    /// Empty for 1:1 calls; the group conversation id for group calls.
    public let groupId: String
    /// Mesh OFFER/ANSWER/ICE: the local account this message targets.
    public let targetAccount: String
    /// GROUP_RING: the full participant list.
    public let participants: [String]

    public init(
        callId: String, type: CallType, sdp: String, ice: String,
        callerAccount: String, groupId: String = "", targetAccount: String = "",
        participants: [String] = []
    ) {
        self.callId = callId
        self.type = type
        self.sdp = sdp
        self.ice = ice
        self.callerAccount = callerAccount
        self.groupId = groupId
        self.targetAccount = targetAccount
        self.participants = participants
    }
}

/// A peer's profile. The caller stores it and fetches any avatar, keeping
/// the processor network-free.
public struct ProfileInfo: Sendable, Codable {
    public struct Avatar: Sendable, Codable {
        public let id: String
        public let key: Data
        public let digest: Data
    }
    public struct Link: Sendable, Codable {
        public let label: String
        public let url: String
        public init(label: String, url: String) {
            self.label = label
            self.url = url
        }
    }
    public let account: String
    public let displayName: String
    public let avatar: Avatar?
    public let revision: Int64
    public let status: String
    public let bio: String
    public let links: [Link]

    public init(account: String, displayName: String, avatar: Avatar?, revision: Int64,
                status: String = "", bio: String = "", links: [Link] = []) {
        self.account = account
        self.displayName = displayName
        self.avatar = avatar
        self.revision = revision
        self.status = status
        self.bio = bio
        self.links = links
    }
}

public struct ProcessedEnvelope: Sendable {
    public enum Outcome: Sendable {
        case stored, applied, duplicate, ignored
    }

    public let outcome: Outcome
    public let peerAccount: String?
    public let conversationId: String?
    public let notification: NotificationContent?
    public let sideEffects: EnvelopeSideEffects
    public let typingStarted: Bool?
    public let groupUpdate: GroupUpdateInfo?
    public let profile: ProfileInfo?
    public let callInfo: CallInfo?
    public let pollInfo: PollInfo?
    public let pollVoteInfo: PollVoteInfo?
    public let screenshotAlert: ScreenshotAlertInfo?
    public let screenSecurityUpdate: ScreenSecurityInfo?
    /// An unsend or edit: the chat's delivered notifications show stale text.
    public var removesNotifications = false
    /// The message whose notification is stale. Notifications that don't
    /// say which message they announce are removed with the whole chat's.
    public var removedMessageId: String?

    public init(
        outcome: Outcome,
        peerAccount: String? = nil,
        conversationId: String? = nil,
        notification: NotificationContent? = nil,
        sideEffects: EnvelopeSideEffects = EnvelopeSideEffects(),
        typingStarted: Bool? = nil,
        groupUpdate: GroupUpdateInfo? = nil,
        profile: ProfileInfo? = nil,
        callInfo: CallInfo? = nil,
        pollInfo: PollInfo? = nil,
        pollVoteInfo: PollVoteInfo? = nil,
        screenshotAlert: ScreenshotAlertInfo? = nil,
        screenSecurityUpdate: ScreenSecurityInfo? = nil
    ) {
        self.outcome = outcome
        self.peerAccount = peerAccount
        self.conversationId = conversationId
        self.notification = notification
        self.sideEffects = sideEffects
        self.typingStarted = typingStarted
        self.groupUpdate = groupUpdate
        self.profile = profile
        self.callInfo = callInfo
        self.pollInfo = pollInfo
        self.pollVoteInfo = pollVoteInfo
        self.screenshotAlert = screenshotAlert
        self.screenSecurityUpdate = screenSecurityUpdate
    }
}

public enum EnvelopeProcessorError: Error, Sendable {
    /// A sealed-sender envelope arrived but no trust root is configured.
    case sealedSenderUnavailable
    /// The plaintext's claimed sender doesn't match the sealed-sender
    /// certificate.
    case senderSpoofed
}

// @unchecked Sendable: SQLCipher runs in serialized threading mode, and the
// callers process one envelope at a time, so session state advances serially.
public struct EnvelopeProcessor: @unchecked Sendable {
    private let storage: SecureStore
    private let engine: CryptoEngine
    private let ownAccountId: String
    private let processLock: CrossProcessLock?
    /// 33-byte serialized sealed-sender trust root. Nil disables sealed messages
    /// (empty envelope sender).
    private let sealedSenderTrustRoot: Data?
    /// The relay drops queued envelopes after 14 days.
    static let maxQueueAgeMs: Int64 = 14 * 24 * 60 * 60 * 1000

    static func durationLabel(_ seconds: Int64) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.weekOfMonth, .day, .hour, .minute, .second]
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds) seconds"
    }

    static func isRelayBlobId(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    private func isGroupControl(_ content: Relay_Content_Content) -> Bool {
        switch content.body {
        case .groupUpdate, .senderKeyDistribution: return true
        default: return false
        }
    }

    /// Must match `MessagingService.relayOfficialAccount`.
    public static let relayOfficialAccount = "relay.official"

    private let log = Logger(subsystem: "com.relaytextingapp.Relay", category: "envelope")

    /// Body prefix of a live-location update (the app's `locationPrefix`).
    /// Updates collapse into one moving bubble per sharer.
    static let liveLocationPrefix = "__relay_loc__"
    static let maxPollOptions = 12
    static let maxPollOptionLength = 100
    static let maxPollQuestionLength = 300

    public init(
        storage: SecureStore,
        engine: CryptoEngine,
        ownAccountId: String = "",
        sealedSenderTrustRoot: Data? = nil,
        processLock: CrossProcessLock? = nil
    ) {
        self.storage = storage
        self.engine = engine
        self.ownAccountId = ownAccountId
        self.sealedSenderTrustRoot = sealedSenderTrustRoot
        self.processLock = processLock
    }

    /// - Parameter blockedAccounts: accounts whose messages are dropped. A sealed
    ///   message's sender is only known after decryption, so blocking happens here.
    /// - Parameter persist: runs in the same transaction as the decrypt, for
    ///   what the caller must keep (the extension's pending control payloads).
    public func process(
        _ envelope: IncomingEnvelope,
        blockedAccounts: Set<String> = [],
        persist: ((ProcessedEnvelope) -> Void)? = nil
    ) throws -> ProcessedEnvelope {
        // Serialize with the other process sharing this database.
        guard let processLock else { return try processAtomically(envelope, blockedAccounts, persist) }
        return try processLock.withLock { try processAtomically(envelope, blockedAccounts, persist) }
    }

    /// Claim, decrypt, store and `persist` commit together. If the process dies
    /// part-way (the extension's 30 s / 24 MB limits), nothing is claimed and
    /// the ratchet hasn't moved, so the redelivered envelope is processed
    /// again instead of being skipped as a duplicate. An error while handling
    /// the decrypted content still commits the decrypt, as before: rolling it
    /// back would lose a newly established session.
    private func processAtomically(
        _ envelope: IncomingEnvelope,
        _ blockedAccounts: Set<String>,
        _ persist: ((ProcessedEnvelope) -> Void)?
    ) throws -> ProcessedEnvelope {
        var handlingError: Error?
        let result: ProcessedEnvelope? = try storage.database.transaction {
            do {
                let result = try processLocked(envelope, blockedAccounts: blockedAccounts)
                persist?(result)
                return result
            } catch let error as HandlingError {
                handlingError = error.underlying
                return nil
            }
        }
        if let handlingError { throw handlingError }
        return result ?? ProcessedEnvelope(outcome: .ignored)
    }

    /// Wraps an error thrown after decryption succeeded.
    private struct HandlingError: Error {
        let underlying: Error
    }

    private func processLocked(
        _ envelope: IncomingEnvelope,
        blockedAccounts: Set<String>
    ) throws -> ProcessedEnvelope {
        guard try storage.messages.claimEnvelope(id: envelope.id) else {
            return ProcessedEnvelope(outcome: .duplicate, peerAccount: envelope.senderAccount)
        }

        // An empty envelope sender marks a sealed-sender message. The sender is
        // recovered from the sealed blob's certificate, not a server-set field.
        let sender: ProtocolAddress
        let plaintext: Data
        var attestedUsername: String?
        if envelope.senderAccount.isEmpty {
            guard let trustRoot = sealedSenderTrustRoot else {
                throw EnvelopeProcessorError.sealedSenderUnavailable
            }
            // Validate the certificate at the time the relay accepted the message,
            // since delivery may be delayed. That time comes from the relay, so clamp
            // it to the queue TTL and to now; a relay can't stretch an expired cert
            // far.
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let oldestPlausibleMs = nowMs - Self.maxQueueAgeMs
            let claimedMs = envelope.serverTimestamp > 0 ? envelope.serverTimestamp : nowMs
            let validationTime = UInt64(min(max(claimedMs, oldestPlausibleMs), nowMs))
            let result = try engine.sealedDecrypt(
                envelope.message.data,
                trustRoot: trustRoot,
                timestampMs: validationTime
            )
            sender = try ProtocolAddress(name: result.senderAccountId, deviceId: result.senderDeviceId)
            plaintext = result.plaintext
            attestedUsername = result.senderUsername
        } else {
            sender = try ProtocolAddress(name: envelope.senderAccount, deviceId: envelope.senderDevice)
            plaintext = try engine.decrypt(envelope.message, from: sender)
        }
        do {
            return try handle(
                envelopeId: envelope.id, sender: sender, plaintext: plaintext,
                attestedUsername: attestedUsername, blockedAccounts: blockedAccounts, mayDefer: true
            )
        } catch {
            throw HandlingError(underlying: error)
        }
    }

    // MARK: Group content that arrived before its group

    /// Group messages that arrived before the group update that makes them
    /// valid (the notification extension can't apply group updates; it saves
    /// them for the app). They're decrypted already, so they're kept here and
    /// re-handled by `replayDeferredGroupContent` once the app has applied the
    /// pending updates. Bounded, and dropped after `deferredMaxAge`.
    private struct DeferredGroupContent: Codable {
        let envelopeId: String
        let senderName: String
        let senderDevice: UInt32
        let attestedUsername: String?
        let plaintext: Data
        let groupId: String
        let savedAt: Date
    }

    private static let deferredPrefix = "deferred-group-content:"
    private static let deferredMaxAge: TimeInterval = 3 * 24 * 3600
    private static let deferredMaxRows = 300

    private func deferGroupContent(
        envelopeId: String, sender: ProtocolAddress, attestedUsername: String?, plaintext: Data, groupId: String
    ) {
        let count = (try? storage.database.query(
            "SELECT COUNT(*) FROM kv WHERE key LIKE ?", [.text(Self.deferredPrefix + "%")]
        ).first?.first?.int64) ?? 0
        guard count < Self.deferredMaxRows else { return }
        let item = DeferredGroupContent(
            envelopeId: envelopeId, senderName: sender.name, senderDevice: sender.deviceId,
            attestedUsername: attestedUsername, plaintext: plaintext, groupId: groupId, savedAt: Date()
        )
        guard let data = try? JSONEncoder().encode(item) else { return }
        let micros = Int64(Date().timeIntervalSince1970 * 1_000_000)
        try? storage.database.run(
            "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
            [.text(Self.deferredPrefix + String(format: "%017lld:", micros) + envelopeId), .blob(data)]
        )
    }

    /// Re-handles deferred group content whose group (and sender's membership)
    /// is now known. Call after applying group updates.
    public func replayDeferredGroupContent(blockedAccounts: Set<String> = []) -> [ProcessedEnvelope] {
        let run = { () -> [ProcessedEnvelope] in
            let rows = (try? storage.database.query(
                "SELECT key, value FROM kv WHERE key LIKE ? ORDER BY key", [.text(Self.deferredPrefix + "%")]
            )) ?? []
            var results: [ProcessedEnvelope] = []
            for row in rows {
                guard let key = row[0].string else { continue }
                guard let data = row[1].data, let item = try? JSONDecoder().decode(DeferredGroupContent.self, from: data),
                      let sender = try? ProtocolAddress(name: item.senderName, deviceId: item.senderDevice)
                else {
                    try? storage.database.run("DELETE FROM kv WHERE key = ?", [.text(key)])
                    continue
                }
                let group = try? storage.messages.group(id: item.groupId)
                let ready = group.map { $0.members.contains(item.senderName) } ?? false
                if !ready {
                    if Date().timeIntervalSince(item.savedAt) > Self.deferredMaxAge {
                        try? storage.database.run("DELETE FROM kv WHERE key = ?", [.text(key)])
                    }
                    continue
                }
                try? storage.database.run("DELETE FROM kv WHERE key = ?", [.text(key)])
                if let result = try? handle(
                    envelopeId: item.envelopeId, sender: sender, plaintext: item.plaintext,
                    attestedUsername: item.attestedUsername, blockedAccounts: blockedAccounts, mayDefer: false
                ) {
                    results.append(result)
                }
            }
            return results
        }
        guard let processLock else { return run() }
        return (try? processLock.withLock { run() }) ?? []
    }

    private func handle(
        envelopeId: String,
        sender: ProtocolAddress,
        plaintext: Data,
        attestedUsername: String?,
        blockedAccounts: Set<String>,
        mayDefer: Bool
    ) throws -> ProcessedEnvelope {
        let content = try Relay_Content_Content(serializedBytes: plaintext)
        let groupId = content.groupID.isEmpty ? nil : content.groupID

        // The sender is whoever's session decrypted this: the certificate identity
        // for sealed messages, the session address otherwise. A sender id in the
        // plaintext is only a claim and must agree, or any contact could pose as
        // anyone, including us via a fake sync copy.
        if !content.senderAccountID.isEmpty, content.senderAccountID != sender.name {
            throw EnvelopeProcessorError.senderSpoofed
        }
        let attestedAccount = sender.name
        // The official "Relay" notices chat is local-only; nothing from the
        // network may land in it.
        if attestedAccount == Self.relayOfficialAccount {
            throw EnvelopeProcessorError.senderSpoofed
        }

        // Drop blocked senders now that the sender is known. Sealed messages
        // can't be filtered earlier because the wire envelope has no sender.
        // The exception is a membership change to a group we're already in:
        // ignoring a blocked admin's removals would leave people they removed
        // on our roster, still getting our group messages.
        if blockedAccounts.contains(attestedAccount) {
            let isKnownGroupUpdate: Bool = {
                guard let groupId, case .groupUpdate = content.body else { return false }
                return ((try? storage.messages.group(id: groupId)) ?? nil) != nil
            }()
            if !isKnownGroupUpdate {
                return ProcessedEnvelope(outcome: .ignored, peerAccount: attestedAccount)
            }
        }

        // The relay-signed certificate names the sender's username, so we never
        // have to ask the relay who wrote to us, which would link sender and
        // recipient. Skip our own devices; their cert names us.
        if let attestedUsername, attestedAccount != ownAccountId {
            recordUsername(attestedUsername, forAccount: attestedAccount)
        }

        // Group content is accepted only from current members of a known group.
        // Group updates (authorized separately by the app) and sender-key
        // distributions (harmless to store) are exempt.
        if let groupId, !isGroupControl(content) {
            // We must still be a member; after leaving or removal the group's traffic
            // is dropped.
            let group = try? storage.messages.group(id: groupId)
            guard let group,
                  ownAccountId.isEmpty || group.members.contains(ownAccountId),
                  attestedAccount == ownAccountId || group.members.contains(attestedAccount)
            else {
                // A group we don't know yet, or a sender not yet on our roster,
                // may just be ahead of a group update the app hasn't applied.
                // (Content for a group we've left is dropped.)
                let maybeEarly = group == nil
                    || (!group!.members.contains(attestedAccount) && group!.members.contains(ownAccountId))
                if mayDefer, maybeEarly, attestedAccount != ownAccountId {
                    deferGroupContent(envelopeId: envelopeId, sender: sender, attestedUsername: attestedUsername,
                                      plaintext: plaintext, groupId: groupId)
                } else {
                    log.warning("dropping group content from a non-member or for an unknown group")
                }
                return ProcessedEnvelope(outcome: .ignored, peerAccount: attestedAccount)
            }
        }

        // A copy of a message we sent from another of our devices.
        let isSyncMessage = !ownAccountId.isEmpty && attestedAccount == ownAccountId && !content.syncRecipient.isEmpty

        // Chat messages go to the group conversation, or the 1:1 conversation with
        // the sender (the recipient, for a sync copy).
        func chatConversation() throws -> String {
            if isSyncMessage, groupId == nil {
                return try storage.messages.conversation(withPeer: content.syncRecipient)
            }
            if let groupId {
                // Not conversation(withPeer:), which is 1:1-only.
                guard let id = try storage.messages.groupConversationId(groupId: groupId) else {
                    throw EnvelopeProcessorError.senderSpoofed
                }
                return id
            }
            // Someone we've never chatted with starts a message request.
            return try storage.messages.conversation(withPeer: attestedAccount, accepted: attestedAccount == ownAccountId)
        }

        // Edits and unsends name their target by timestamp only, so apply them
        // only to a message this sender wrote: their incoming message (in a group,
        // matching sender_account), or our outgoing one for a sync copy. Returns
        // that row's id; timestamps are sender-chosen, so other rows sharing it
        // (someone else's message) must never be touched.
        func targetAuthoredBySender(timestamp: Int64, conversationId: String) -> String? {
            let rows = (try? storage.database.query(
                "SELECT id, is_outgoing, sender_account FROM messages WHERE conversation_id = ? AND timestamp = ?",
                [.text(conversationId), .integer(timestamp)]
            )) ?? []
            return rows.first { row in
                let outgoing = row[1].int64 == 1
                if isSyncMessage { return outgoing }
                if outgoing { return false }
                if row[2].string == MessageStore.systemSender { return false }
                return groupId == nil || row[2].string == attestedAccount
            }?[0].string
        }

        func resolvedQuote(targetTimestamp: Int64, claimedAuthor: String, conversationId: String) -> QuotedMessage {
            let rows = (try? storage.database.query(
                """
                SELECT is_outgoing, sender_account, body, deleted FROM messages
                WHERE conversation_id = ? AND timestamp = ? AND (sender_account IS NULL OR sender_account <> ?)
                """,
                [.text(conversationId), .integer(targetTimestamp), .text(MessageStore.systemSender)]
            )) ?? []
            // The row the claimed author wrote, if we have it.
            let match = rows.first { row in
                let outgoing = row[0].int64 == 1
                let author = outgoing
                    ? ownAccountId
                    : (row[1].string ?? (groupId == nil ? (isSyncMessage ? content.syncRecipient : attestedAccount) : ""))
                return author == claimedAuthor
            }
            guard let match, match[3].int64 != 1 else {
                // Not found (expired, deleted, never received): keep the link,
                // show no text.
                return QuotedMessage(targetTimestamp: targetTimestamp, author: claimedAuthor, text: "")
            }
            return QuotedMessage(targetTimestamp: targetTimestamp, author: claimedAuthor, text: match[2].string ?? "")
        }

        // Until the user accepts a changed safety number, the new key may still
        // deliver messages (shown under the warning), but not rewrite history or
        // settings: that's what a relay posing as this contact would do.
        let senderSettled = attestedAccount == ownAccountId
            || IdentityAcknowledgement.isSettled(peer: attestedAccount, storage: storage)

        func applyDisappearingTimer(_ ms: Int64, conversationId: String, isSync: Bool) {
            // Only a set timer is applied. Every message carries the sender's
            // current setting and an unset field reads as 0, so 0 can't mean
            // "off": a reply from someone who hasn't seen the change yet would
            // switch it off. (Turning the timer off isn't carried this way.)
            guard senderSettled, ms > 0,
                  isSync || (try? storage.messages.isAccepted(conversationId: conversationId)) == true else { return }
            // Round up so 1–999 ms can't read as "off"; out-of-range values are ignored.
            let secs = (ms / 1000) + (ms % 1000 == 0 ? 0 : 1)
            guard secs <= MessageStore.maxDisappearingSeconds,
                  let current = try? storage.messages.disappearingSeconds(conversationId: conversationId),
                  secs != current
            else { return }
            try? storage.messages.setDisappearingSeconds(conversationId, seconds: secs)
            let who = isSync ? "You" : (groupId == nil ? "They" : "A member")
            _ = try? storage.messages.insertMessage(
                id: UUID().uuidString, conversationId: conversationId, isOutgoing: false,
                body: "\(who) set disappearing messages to \(Self.durationLabel(secs))",
                timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                status: .received, senderAccount: MessageStore.systemSender
            )
        }

        // Announce-only: only admins post (messages and polls). A modified
        // client could still send; don't show it. (Legacy groups with no
        // admins are open.)
        let blockedByAnnounceOnly: Bool = {
            guard let groupId, attestedAccount != ownAccountId,
                  let group = try? storage.messages.group(id: groupId)
            else { return false }
            return group.isAnnounceOnly && !group.admins.isEmpty && !group.admins.contains(attestedAccount)
        }()

        // Messages sort by the sender's timestamp and the read marker follows
        // the newest one, so a far-future timestamp would pin a message to the
        // bottom of the chat and the chat to the top of the list, and make
        // everything after it look read. Allow a day of clock skew.
        let latestPlausibleTimestamp = Int64(Date().timeIntervalSince1970 * 1000) + 86_400_000
        func isPlausible(_ timestamp: Int64) -> Bool {
            timestamp > 0 && timestamp <= latestPlausibleTimestamp
        }

        switch content.body {
        case .text(let text):
            guard isPlausible(text.timestamp) else {
                log.warning("dropping a message with an implausible timestamp")
                return ProcessedEnvelope(outcome: .ignored, peerAccount: attestedAccount)
            }
            if blockedByAnnounceOnly {
                log.warning("dropping a non-admin message in an announce-only group")
                return ProcessedEnvelope(outcome: .ignored, peerAccount: attestedAccount)
            }
            let conversationId = try chatConversation()
            // Live location: every update from one sharer updates one bubble keyed by
            // conversation and sender. Notify only when the share first appears.
            if text.body.hasPrefix(Self.liveLocationPrefix) {
                let locId = "liveloc:\(conversationId):\(attestedAccount)"
                let wasInsert = (try? storage.messages.upsertLiveLocation(
                    id: locId, conversationId: conversationId, isOutgoing: false,
                    body: text.body, timestamp: text.timestamp,
                    senderAccount: groupId == nil ? nil : attestedAccount
                )) ?? false
                return ProcessedEnvelope(
                    outcome: .applied,
                    peerAccount: attestedAccount,
                    conversationId: conversationId,
                    notification: wasInsert
                        ? NotificationContent(senderAccount: attestedAccount, conversationId: conversationId, body: "📍 Shared live location")
                        : nil
                )
            }
            // A quote shows the original as we have it, never the sender's copy:
            // otherwise anyone could put words in someone else's mouth (or ours).
            let quote: QuotedMessage? = text.hasQuote
                ? resolvedQuote(targetTimestamp: text.quote.targetTimestamp, claimedAuthor: text.quote.author,
                                conversationId: conversationId)
                : nil
            // Relay blob ids are 32 lowercase hex chars. Drop anything else; the id is
            // used in a request path and as a cache file name.
            let attachments = text.attachments.filter { Self.isRelayBlobId($0.id) }.map { p in
                StoredAttachment(
                    id: p.id, key: p.key, digest: p.digest, contentType: p.contentType,
                    size: Int64(clamping: p.size), filename: p.filename.isEmpty ? nil : p.filename,
                    width: Int(p.width), height: Int(p.height), isDownloaded: false
                )
            }
            // Apply the sender's disappearing-message timer before inserting, so it
            // covers this message. A message request can't change it.
            applyDisappearingTimer(content.expiresAfterMs, conversationId: conversationId, isSync: isSyncMessage)
            if isSyncMessage {
                // Our own message from another device: store as outgoing under the
                // envelope id, so duplicates are ignored.
                do {
                    _ = try storage.messages.insertMessage(
                        id: envelopeId, conversationId: conversationId, isOutgoing: true,
                        body: text.body, timestamp: text.timestamp, status: .sent,
                        replyTo: quote, attachments: attachments, senderAccount: nil
                    )
                } catch {
                    log.error("insertMessage (sync): \(error.localizedDescription)")
                }
                return ProcessedEnvelope(outcome: .applied, peerAccount: content.syncRecipient, conversationId: conversationId)
            }
            let inserted = try storage.messages.insertMessage(
                id: envelopeId, conversationId: conversationId, isOutgoing: false,
                body: text.body, timestamp: text.timestamp, status: .received,
                replyTo: quote, attachments: attachments,
                senderAccount: groupId == nil ? nil : attestedAccount
            )
            var effects = EnvelopeSideEffects()
            if inserted {
                // Receipt goes to the author; the caller adds the group context.
                effects.deliveryReceiptTimestamp = text.timestamp
            }
            let preview = text.body.isEmpty && !attachments.isEmpty ? "📷 Photo" : text.body
            return ProcessedEnvelope(
                outcome: inserted ? .stored : .duplicate,
                peerAccount: attestedAccount,
                conversationId: conversationId,
                notification: inserted
                    ? NotificationContent(senderAccount: attestedAccount, conversationId: conversationId, body: preview, messageId: envelopeId)
                    : nil,
                sideEffects: effects
            )

        case .reaction(let reaction):
            let conversationId = try chatConversation()
            // A sync copy is our own reaction from another device: store it as ours
            // and don't notify.
            try storage.messages.setReaction(
                conversationId: conversationId, targetTimestamp: reaction.targetTimestamp,
                author: attestedAccount, isOutgoing: isSyncMessage,
                emoji: reaction.emoji, remove: reaction.remove
            )
            return ProcessedEnvelope(
                outcome: .applied, peerAccount: attestedAccount, conversationId: conversationId,
                notification: (reaction.remove || isSyncMessage) ? nil
                    : NotificationContent(senderAccount: attestedAccount, conversationId: conversationId, body: "Reacted \(reaction.emoji)")
            )

        case .receipt(let receipt):
            let conversationId = try chatConversation()
            let status: MessageStatus = receipt.type == .read ? .read : .delivered
            if groupId != nil {
                // Group: record this member's state on the author's message.
                try storage.messages.recordGroupReceipt(
                    conversationId: conversationId, member: attestedAccount,
                    timestamps: receipt.messageTimestamps, status: status
                )
            } else {
                try storage.messages.applyReceipt(
                    conversationId: conversationId, timestamps: receipt.messageTimestamps, status: status
                )
            }
            return ProcessedEnvelope(outcome: .applied, peerAccount: attestedAccount, conversationId: conversationId)

        case .delete(let deletion):
            let conversationId = try chatConversation()
            guard senderSettled,
                  let targetId = targetAuthoredBySender(timestamp: deletion.targetTimestamp, conversationId: conversationId) else {
                log.warning("ignoring unsend for a message the sender didn't write")
                return ProcessedEnvelope(outcome: .ignored, peerAccount: attestedAccount, conversationId: conversationId)
            }
            try storage.messages.markDeleted(id: targetId)
            var result = ProcessedEnvelope(outcome: .applied, peerAccount: attestedAccount, conversationId: conversationId)
            result.removesNotifications = true
            result.removedMessageId = targetId
            return result

        case .edit(let edit):
            let conversationId = try chatConversation()
            guard senderSettled,
                  let targetId = targetAuthoredBySender(timestamp: edit.targetTimestamp, conversationId: conversationId) else {
                log.warning("ignoring edit for a message the sender didn't write")
                return ProcessedEnvelope(outcome: .ignored, peerAccount: attestedAccount, conversationId: conversationId)
            }
            try storage.messages.editMessage(id: targetId, newBody: edit.newBody)
            var result = ProcessedEnvelope(outcome: .applied, peerAccount: attestedAccount, conversationId: conversationId)
            result.removesNotifications = true
            result.removedMessageId = targetId
            return result

        case .senderKeyDistribution(let skd):
            // Store the sender's sender key so their group messages decrypt.
            try engine.processSenderKeyDistribution(skd.data, from: sender)
            return ProcessedEnvelope(outcome: .applied, peerAccount: attestedAccount)

        case .groupUpdate(let update):
            let info = GroupUpdateInfo(
                groupId: content.groupID,
                action: Self.action(update.action),
                actor: update.actor,
                target: update.target,
                name: ProfileText.groupName(update.name),
                description: ProfileText.groupDescription(update.description_p),
                avatarId: update.hasAvatar && Self.isRelayBlobId(update.avatar.id) ? update.avatar.id : "",
                avatarKey: update.hasAvatar ? update.avatar.key : Data(),
                avatarDigest: update.hasAvatar ? update.avatar.digest : Data(),
                members: update.members,
                admins: update.admins,
                announceOnly: update.announceOnly,
                screenSecurity: update.screenSecurity,
                revision: update.revision,
                distributionId: update.distributionID,
                inviteKey: update.inviteKey
            )
            return ProcessedEnvelope(outcome: .applied, peerAccount: attestedAccount, groupUpdate: info)

        case .poll(let received):
            if blockedByAnnounceOnly || !isPlausible(received.timestamp) {
                log.warning("dropping a non-admin poll in an announce-only group")
                return ProcessedEnvelope(outcome: .ignored, peerAccount: attestedAccount)
            }
            var poll = received
            poll.question = String(poll.question.prefix(Self.maxPollQuestionLength))
            poll.options = poll.options.prefix(Self.maxPollOptions).map { String($0.prefix(Self.maxPollOptionLength)) }
            let conversationId = try chatConversation()
            let pollInfo = PollInfo(
                question: poll.question,
                options: poll.options,
                multiSelect: poll.multiSelect,
                timestamp: poll.timestamp,
                conversationId: conversationId,
                author: attestedAccount
            )
            // Stored with a JSON body so the UI can render the question and options.
            let pollPayload = PollPayload(question: poll.question, options: Array(poll.options), multiSelect: poll.multiSelect)
            let body = "__poll__:" + (pollPayload.encode() ?? poll.question)
            var inserted = false
            do {
                inserted = try storage.messages.insertMessage(
                    id: envelopeId, conversationId: conversationId, isOutgoing: false,
                    body: body, timestamp: poll.timestamp, status: .received,
                    senderAccount: groupId == nil ? nil : attestedAccount
                )
            } catch {
                log.error("insertMessage (poll): \(error.localizedDescription)")
            }
            // A redelivered poll is already stored and was already announced.
            return ProcessedEnvelope(
                outcome: inserted ? .stored : .duplicate, peerAccount: attestedAccount, conversationId: conversationId,
                notification: inserted
                    ? NotificationContent(senderAccount: attestedAccount, conversationId: conversationId, body: "📊 Poll: \(poll.question)", messageId: envelopeId)
                    : nil,
                pollInfo: inserted ? pollInfo : nil
            )

        case .pollVote(let vote):
            let conversationId = try chatConversation()
            // Option indexes the poll could actually have, each once.
            let selectedOptions = Array(Set(vote.selectedOptions.map { Int($0) }
                .filter { (0..<Self.maxPollOptions).contains($0) })).sorted()
            do {
                try storage.messages.upsertPollVote(
                    conversationId: conversationId,
                    pollAuthor: vote.pollAuthor,
                    pollTimestamp: vote.pollTimestamp,
                    voterAccount: attestedAccount,
                    selectedOptions: selectedOptions,
                    votedAt: vote.timestamp
                )
            } catch {
                log.error("upsertPollVote: \(error.localizedDescription)")
            }
            let voteInfo = PollVoteInfo(
                pollAuthor: vote.pollAuthor,
                pollTimestamp: vote.pollTimestamp,
                selectedOptions: selectedOptions,
                timestamp: vote.timestamp,
                conversationId: conversationId,
                voterAccount: attestedAccount
            )
            return ProcessedEnvelope(outcome: .applied, peerAccount: attestedAccount, conversationId: conversationId, pollVoteInfo: voteInfo)

        case .profile(let profile):
            let avatar: ProfileInfo.Avatar? = profile.hasAvatar
                && Self.isRelayBlobId(profile.avatar.id)
                ? ProfileInfo.Avatar(id: profile.avatar.id, key: profile.avatar.key, digest: profile.avatar.digest)
                : nil
            let info = ProfileInfo(
                account: attestedAccount,
                displayName: ProfileText.name(profile.displayName),
                avatar: avatar,
                revision: profile.timestamp,
                status: ProfileText.status(profile.status),
                bio: ProfileText.bio(profile.bio),
                links: ProfileText.links(profile.links.map { ($0.label, $0.url) })
                    .map { ProfileInfo.Link(label: $0.label, url: $0.url) }
            )
            return ProcessedEnvelope(outcome: .applied, peerAccount: attestedAccount, profile: info)

        case .call(let call):
            let isNonEphemeral: Bool = switch call.type {
                case .offer, .hangup, .groupRing, .linkJoinRequest, .linkAdmit, .linkDeny: true
                default: false
            }
            if !isNonEphemeral {
                try? storage.messages.releaseEnvelope(id: envelopeId)
            }
            let callType: CallInfo.CallType = switch call.type {
                case .offer:      .offer
                case .answer:     .answer
                case .ice:        .ice
                case .hangup:     .hangup
                case .busy:       .busy
                case .ringing:    .ringing
                case .groupRing:  .groupRing
                case .groupJoin:  .groupJoin
                case .groupLeave: .groupLeave
                case .linkJoinRequest: .linkJoinRequest
                case .linkAdmit:  .linkAdmit
                case .linkRoster: .linkRoster
                case .linkDeny:   .linkDeny
                case .UNRECOGNIZED: .hangup
            }
            let info = CallInfo(
                callId: call.callID, type: callType,
                sdp: call.sdp, ice: call.ice,
                callerAccount: attestedAccount,
                groupId: call.groupID,
                targetAccount: call.targetAccount,
                participants: call.participants
            )
            return ProcessedEnvelope(outcome: .applied, peerAccount: attestedAccount, callInfo: info)

        case .typing(let typing):
            // Ephemeral, so release the dedup claim. In a group, report the existing
            // conversation; never create one for a typing frame.
            try? storage.messages.releaseEnvelope(id: envelopeId)
            let groupConversation = groupId.flatMap { try? storage.messages.groupConversationId(groupId: $0) }
            if groupId != nil && groupConversation == nil {
                return ProcessedEnvelope(outcome: .ignored, peerAccount: attestedAccount)
            }
            return ProcessedEnvelope(
                outcome: .ignored, peerAccount: attestedAccount,
                conversationId: groupConversation,
                typingStarted: typing.action == .started
            )

        case .screenshot(let shot):
            // Queued, not ephemeral. The caller inserts the in-chat notice.
            let conversationId = try chatConversation()
            return ProcessedEnvelope(
                outcome: .applied, peerAccount: attestedAccount, conversationId: conversationId,
                screenshotAlert: ScreenshotAlertInfo(
                    conversationId: conversationId,
                    senderAccount: attestedAccount,
                    timestamp: shot.timestamp))

        case .screenSecurityUpdate(let upd):
            // The caller stores it as the peer's side.
            let conversationId = try chatConversation()
            return ProcessedEnvelope(
                outcome: .applied, peerAccount: attestedAccount, conversationId: conversationId,
                screenSecurityUpdate: ScreenSecurityInfo(
                    conversationId: conversationId,
                    senderAccount: attestedAccount,
                    enabled: upd.enabled,
                    timestamp: upd.timestamp))

        case .deviceInfo(let info):
            // Only our own devices may label themselves; anyone else's DeviceInfo is
            // ignored. Stored per sender device, newest wins.
            guard attestedAccount == ownAccountId, !ownAccountId.isEmpty else {
                return ProcessedEnvelope(outcome: .ignored, peerAccount: attestedAccount)
            }
            recordDeviceLabel(info, forDevice: sender.deviceId)
            return ProcessedEnvelope(outcome: .applied, peerAccount: attestedAccount)

        case .none:
            return ProcessedEnvelope(outcome: .ignored, peerAccount: attestedAccount)
        }
    }

    /// JSON shape the app's `DeviceLabel` decodes (kv `devinfo:<deviceId>`).
    private struct StoredDeviceLabel: Codable {
        let model: String
        let region: String
        let updatedAt: Int64
    }

    private func recordDeviceLabel(_ info: Relay_Content_DeviceInfo, forDevice deviceId: UInt32) {
        let key = "devinfo:\(deviceId)"
        if let existing = (try? storage.database.query("SELECT value FROM kv WHERE key = ?", [.text(key)]))?
            .first?.first?.data,
           let old = try? JSONDecoder().decode(StoredDeviceLabel.self, from: existing),
           old.updatedAt >= info.updatedAt {
            return
        }
        let label = StoredDeviceLabel(
            model: String(info.model.prefix(64)),
            region: String(info.region.prefix(96)),
            updatedAt: info.updatedAt)
        guard let data = try? JSONEncoder().encode(label) else { return }
        try? storage.database.run(
            "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)", [.text(key), .blob(data)])
    }

    private static func action(_ a: Relay_Content_GroupUpdate.Action) -> GroupAction {
        switch a {
        case .create: .create
        case .add: .add
        case .remove: .remove
        case .leave: .leave
        case .rename: .rename
        case .describe: .describe
        case .avatar: .avatar
        case .promoteAdmin: .promoteAdmin
        case .demoteAdmin: .demoteAdmin
        case .setAnnounceOnly: .setAnnounceOnly
        case .setScreenSecurity: .setScreenSecurity
        default: .unknown
        }
    }

    /// Caches a certificate-attested username under `un:<account>`, where the app
    /// reads it, and on the 1:1 conversation if there is one.
    private func recordUsername(_ username: String, forAccount account: String) {
        try? storage.database.run(
            "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
            [.text("un:\(account)"), .blob(Data(username.utf8))]
        )
        try? storage.database.run(
            "UPDATE conversations SET peer_username = ? WHERE peer_account = ?",
            [.text(username), .text(account)]
        )
    }
}
