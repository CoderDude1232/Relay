//
//  EnvelopeProcessor.swift
//  RelayCore
//
//  The single, shared incoming pipeline. Both the app (over the WebSocket)
//  and the Notification Service Extension (from the push payload) run an
//  envelope through here: it claims the envelope exactly once, decrypts it
//  (advancing the Double Ratchet / applying sender keys in the shared store),
//  applies the content, and returns what happened. Network side-effects
//  (receipts, username lookups, group re-sync) are *returned* rather than
//  performed, so the NSE can ignore them.
//

import CryptoCore
import Foundation
import LibSignalClient
import OSLog
import RelayKit
import SecureStorage
import SwiftProtobuf

/// Compact serialisation of a poll stored in the message body after the `__poll__:` prefix.
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
    public var backfillUsernameForAccount: String?

    public init(deliveryReceiptTimestamp: Int64? = nil, backfillUsernameForAccount: String? = nil) {
        self.deliveryReceiptTimestamp = deliveryReceiptTimestamp
        self.backfillUsernameForAccount = backfillUsernameForAccount
    }
}

/// A user-visible message worth surfacing as a notification.
public struct NotificationContent: Sendable {
    public let senderAccount: String
    public let conversationId: String
    public let body: String
}

public enum GroupAction: Sendable {
    case create, add, remove, leave, rename, describe, avatar
    case promoteAdmin, demoteAdmin, setAnnounceOnly
    case unknown
}

/// A group membership/metadata change. The `members` field carries the full
/// updated roster (present on CREATE/ADD/REMOVE/LEAVE) so recipients can keep
/// their local copy current without a server round-trip.
public struct GroupUpdateInfo: Sendable {
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
    public let revision: Int64
    /// The group's sender-key epoch after this change (empty = unchanged).
    public let distributionId: String
    /// Group invite capability (empty = none/unchanged).
    public let inviteKey: Data

    public init(
        groupId: String, action: GroupAction, actor: String, target: String, name: String,
        description: String = "", avatarId: String = "", avatarKey: Data = Data(), avatarDigest: Data = Data(),
        members: [String] = [], admins: [String] = [], announceOnly: Bool = false, revision: Int64 = 0,
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
        self.revision = revision
        self.distributionId = distributionId
        self.inviteKey = inviteKey
    }
}

/// An incoming poll message.
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

/// An incoming poll vote.
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

/// An incoming call signalling message. The caller routes it to CallManager.
public struct CallInfo: Sendable {
    public enum CallType: Sendable, Codable {
        case offer, answer, ice, hangup, busy, ringing
        case groupRing, groupJoin, groupLeave
    }
    public let callId: String
    public let type: CallType
    public let sdp: String
    public let ice: String
    public let callerAccount: String
    /// Empty for 1:1 calls; set to the group conversation ID for group calls.
    public let groupId: String
    /// For mesh OFFER/ANSWER/ICE: which local account this message targets.
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

/// A peer's self-set profile. The caller stores it (and downloads the avatar
/// blob, if any) — kept out of the processor so it stays network-free.
public struct ProfileInfo: Sendable {
    public struct Avatar: Sendable {
        public let id: String
        public let key: Data
        public let digest: Data
    }
    public let account: String
    public let displayName: String
    public let avatar: Avatar?
    public let revision: Int64
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
        pollVoteInfo: PollVoteInfo? = nil
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
    }
}

// @unchecked Sendable: SQLCipher runs in serialized threading mode (thread-safe),
// and libsignal's session state is advanced serially via the single-envelope
// processing guarantee at the call site.
public enum EnvelopeProcessorError: Error, Sendable {
    /// A sealed-sender envelope arrived but no trust root is configured to
    /// validate the sender certificate.
    case sealedSenderUnavailable
    /// The plaintext claimed a sender that doesn't match the sealed-sender
    /// certificate — a spoof attempt.
    case senderSpoofed
}

public struct EnvelopeProcessor: @unchecked Sendable {
    private let storage: SecureStore
    private let engine: CryptoEngine
    private let ownAccountId: String
    /// 33-byte serialized public key of the sealed-sender trust root. Required
    /// to decrypt sealed messages (empty envelope sender); nil disables them.
    private let sealedSenderTrustRoot: Data?
    private let log = Logger(subsystem: "com.relaytextingapp.Relay", category: "envelope")

    /// Body prefix marking a live-location update (mirrors the app's
    /// `locationPrefix`). These collapse into a single moving bubble per sharer.
    static let liveLocationPrefix = "__relay_loc__"

    public init(
        storage: SecureStore,
        engine: CryptoEngine,
        ownAccountId: String = "",
        sealedSenderTrustRoot: Data? = nil
    ) {
        self.storage = storage
        self.engine = engine
        self.ownAccountId = ownAccountId
        self.sealedSenderTrustRoot = sealedSenderTrustRoot
    }

    /// - Parameter blockedAccounts: accounts whose messages should be dropped.
    ///   For sealed-sender messages the sender is only known after decryption,
    ///   so blocking is enforced here (post-decrypt) rather than at the wire.
    public func process(
        _ envelope: IncomingEnvelope,
        blockedAccounts: Set<String> = []
    ) throws -> ProcessedEnvelope {
        guard try storage.messages.claimEnvelope(id: envelope.id) else {
            return ProcessedEnvelope(outcome: .duplicate, peerAccount: envelope.senderAccount)
        }

        // An empty envelope sender marks a sealed-sender message: the relay
        // stripped the sender, so we recover it cryptographically from the
        // sealed blob's certificate instead of trusting a server-stamped field.
        let sender: ProtocolAddress
        let plaintext: Data
        if envelope.senderAccount.isEmpty {
            guard let trustRoot = sealedSenderTrustRoot else {
                throw EnvelopeProcessorError.sealedSenderUnavailable
            }
            // Validate the certificate at the time the relay accepted the
            // message (its cert was valid then, even if delivery was delayed).
            let validationTime: UInt64 = envelope.serverTimestamp > 0
                ? UInt64(envelope.serverTimestamp)
                : UInt64(Date().timeIntervalSince1970 * 1000)
            let result = try engine.sealedDecrypt(
                envelope.message.data,
                trustRoot: trustRoot,
                timestampMs: validationTime
            )
            sender = try ProtocolAddress(name: result.senderAccountId, deviceId: result.senderDeviceId)
            plaintext = result.plaintext
        } else {
            sender = try ProtocolAddress(name: envelope.senderAccount, deviceId: envelope.senderDevice)
            plaintext = try engine.decrypt(envelope.message, from: sender)
        }
        let content = try Relay_Content_Content(serializedBytes: plaintext)
        let groupId = content.groupID.isEmpty ? nil : content.groupID

        // For sealed messages the certificate-recovered identity is authoritative;
        // if the plaintext also names a sender, it must agree (else it's a spoof).
        if envelope.senderAccount.isEmpty,
           !content.senderAccountID.isEmpty,
           content.senderAccountID != sender.name {
            throw EnvelopeProcessorError.senderSpoofed
        }

        // Prefer the E2E-attested sender identity over the server-stamped
        // envelope field (server could be compelled to lie). For sealed
        // messages `sender.name` is the cert-recovered account.
        let attestedAccount = content.senderAccountID.isEmpty ? sender.name : content.senderAccountID

        // Now that we know who really sent this (post-decrypt), drop it if the
        // sender is blocked. Sealed messages can't be filtered any earlier since
        // the wire envelope carries no sender.
        if blockedAccounts.contains(attestedAccount) {
            return ProcessedEnvelope(outcome: .ignored, peerAccount: attestedAccount)
        }

        // Sync message: sent by own account to own other devices carrying a copy
        // of a message we sent from another device.
        let isSyncMessage = !ownAccountId.isEmpty && attestedAccount == ownAccountId && !content.syncRecipient.isEmpty

        // A chat message lands in the group conversation (keyed by group id)
        // or the 1:1 conversation with the sender (or sync recipient on sync).
        func chatConversation() throws -> String {
            if isSyncMessage {
                return try storage.messages.conversation(withPeer: content.syncRecipient)
            }
            return try storage.messages.conversation(withPeer: groupId ?? attestedAccount)
        }

        switch content.body {
        case .text(let text):
            let conversationId = try chatConversation()
            // Live location: collapse every update from one sharer into a single
            // moving bubble (keyed by conversation + sender) instead of inserting
            // a fresh bubble each tick. Notify only when the share first appears.
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
            let quote: QuotedMessage? = text.hasQuote
                ? QuotedMessage(targetTimestamp: text.quote.targetTimestamp, author: text.quote.author, text: text.quote.text)
                : nil
            let attachments = text.attachments.map { p in
                StoredAttachment(
                    id: p.id, key: p.key, digest: p.digest, contentType: p.contentType,
                    size: Int64(p.size), filename: p.filename.isEmpty ? nil : p.filename,
                    width: Int(p.width), height: Int(p.height), isDownloaded: false
                )
            }
            // Sync the disappearing-messages timer if the sender set one.
            // Do this before insertMessage so the new timer applies to this message.
            if content.expiresAfterMs > 0 {
                let secs = content.expiresAfterMs / 1000
                try? storage.messages.setDisappearingSeconds(conversationId, seconds: secs)
            }
            if isSyncMessage {
                // Store as outgoing — this is our own message from another device.
                // Use the envelope id as the local id; duplicates are silently ignored.
                do {
                    _ = try storage.messages.insertMessage(
                        id: envelope.id, conversationId: conversationId, isOutgoing: true,
                        body: text.body, timestamp: text.timestamp, status: .sent,
                        replyTo: quote, attachments: attachments, senderAccount: nil
                    )
                } catch {
                    log.error("insertMessage (sync): \(error.localizedDescription)")
                }
                return ProcessedEnvelope(outcome: .applied, peerAccount: content.syncRecipient, conversationId: conversationId)
            }
            let inserted = try storage.messages.insertMessage(
                id: envelope.id, conversationId: conversationId, isOutgoing: false,
                body: text.body, timestamp: text.timestamp, status: .received,
                replyTo: quote, attachments: attachments,
                senderAccount: groupId == nil ? nil : attestedAccount
            )
            var effects = EnvelopeSideEffects()
            if inserted {
                // Send a delivery receipt back to the author (in a group the
                // sender's account; the caller adds the group context).
                effects.deliveryReceiptTimestamp = text.timestamp
            }
            if groupId == nil, !hasUsername(conversationId: conversationId) {
                effects.backfillUsernameForAccount = attestedAccount
            }
            let preview = text.body.isEmpty && !attachments.isEmpty ? "📷 Photo" : text.body
            return ProcessedEnvelope(
                outcome: inserted ? .stored : .duplicate,
                peerAccount: attestedAccount,
                conversationId: conversationId,
                notification: inserted
                    ? NotificationContent(senderAccount: attestedAccount, conversationId: conversationId, body: preview)
                    : nil,
                sideEffects: effects
            )

        case .reaction(let reaction):
            let conversationId = try chatConversation()
            // A sync copy is our own reaction echoed to our other device — store it
            // as ours (isOutgoing) and never notify.
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
                // Group: record this member's state for the author's messages.
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
            try storage.messages.markDeleted(conversationId: conversationId, targetTimestamp: deletion.targetTimestamp)
            return ProcessedEnvelope(outcome: .applied, peerAccount: attestedAccount, conversationId: conversationId)

        case .edit(let edit):
            let conversationId = try chatConversation()
            try storage.messages.editMessage(
                conversationId: conversationId,
                targetTimestamp: edit.targetTimestamp,
                newBody: edit.newBody
            )
            return ProcessedEnvelope(outcome: .applied, peerAccount: attestedAccount, conversationId: conversationId)

        case .senderKeyDistribution(let skd):
            // Store the sender's group sender key so their .senderKey group
            // messages decrypt from here on.
            try engine.processSenderKeyDistribution(skd.data, from: sender)
            return ProcessedEnvelope(outcome: .applied, peerAccount: attestedAccount)

        case .groupUpdate(let update):
            let info = GroupUpdateInfo(
                groupId: content.groupID,
                action: Self.action(update.action),
                actor: update.actor,
                target: update.target,
                name: update.name,
                description: update.description_p,
                avatarId: update.hasAvatar ? update.avatar.id : "",
                avatarKey: update.hasAvatar ? update.avatar.key : Data(),
                avatarDigest: update.hasAvatar ? update.avatar.digest : Data(),
                members: update.members,
                admins: update.admins,
                announceOnly: update.announceOnly,
                revision: update.revision,
                distributionId: update.distributionID,
                inviteKey: update.inviteKey
            )
            return ProcessedEnvelope(outcome: .applied, peerAccount: attestedAccount, groupUpdate: info)

        case .poll(let poll):
            let conversationId = try chatConversation()
            let pollInfo = PollInfo(
                question: poll.question,
                options: poll.options,
                multiSelect: poll.multiSelect,
                timestamp: poll.timestamp,
                conversationId: conversationId,
                author: attestedAccount
            )
            // Store as a message with a JSON body so the UI can render question + options.
            let pollPayload = PollPayload(question: poll.question, options: Array(poll.options), multiSelect: poll.multiSelect)
            let body = "__poll__:" + (pollPayload.encode() ?? poll.question)
            do {
                _ = try storage.messages.insertMessage(
                    id: envelope.id, conversationId: conversationId, isOutgoing: false,
                    body: body, timestamp: poll.timestamp, status: .received,
                    senderAccount: groupId == nil ? nil : attestedAccount
                )
            } catch {
                log.error("insertMessage (poll): \(error.localizedDescription)")
            }
            return ProcessedEnvelope(
                outcome: .stored, peerAccount: attestedAccount, conversationId: conversationId,
                notification: NotificationContent(senderAccount: attestedAccount, conversationId: conversationId, body: "📊 Poll: \(poll.question)"),
                pollInfo: pollInfo
            )

        case .pollVote(let vote):
            let conversationId = try chatConversation()
            let selectedOptions = vote.selectedOptions.map { Int($0) }
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
                ? ProfileInfo.Avatar(id: profile.avatar.id, key: profile.avatar.key, digest: profile.avatar.digest)
                : nil
            let info = ProfileInfo(
                account: attestedAccount,
                displayName: profile.displayName,
                avatar: avatar,
                revision: profile.timestamp
            )
            return ProcessedEnvelope(outcome: .applied, peerAccount: attestedAccount, profile: info)

        case .call(let call):
            // Release the dedup slot for ephemeral call messages.
            let isNonEphemeral = call.type == .offer || call.type == .hangup || call.type == .groupRing
            if !isNonEphemeral {
                try? storage.messages.releaseEnvelope(id: envelope.id)
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
            // Ephemeral, 1:1 only for now — release the dedup claim.
            try? storage.messages.releaseEnvelope(id: envelope.id)
            return ProcessedEnvelope(
                outcome: .ignored, peerAccount: attestedAccount,
                typingStarted: groupId == nil ? (typing.action == .started) : nil
            )

        case .none:
            return ProcessedEnvelope(outcome: .ignored, peerAccount: attestedAccount)
        }
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
        default: .unknown
        }
    }

    private func hasUsername(conversationId: String) -> Bool {
        let username = try? storage.database.query(
            "SELECT peer_username FROM conversations WHERE id = ?", [.text(conversationId)]
        ).first?.first?.string
        return (username ?? nil) != nil
    }
}
