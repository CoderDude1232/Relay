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

public enum GroupAction: Sendable, Codable {
    case create, add, remove, leave, rename, describe, avatar
    case promoteAdmin, demoteAdmin, setAnnounceOnly, setScreenSecurity
    case unknown
}

/// A group membership/metadata change. The `members` field carries the full
/// updated roster (present on CREATE/ADD/REMOVE/LEAVE) so recipients can keep
/// their local copy current without a server round-trip.
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
    /// New group screenshot-hide state (SET_SCREEN_SECURITY action).
    public let screenSecurity: Bool
    public let revision: Int64
    /// The group's sender-key epoch after this change (empty = unchanged).
    public let distributionId: String
    /// Group invite capability (empty = none/unchanged).
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

/// The sender took a screenshot in a conversation (sent regardless of the hide
/// setting). The caller shows an in-chat notice.
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

/// A 1:1 peer's screenshot-hide preference. The caller stores it as the peer's
/// side of the OR that decides effective hiding.
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
    static func isRelayBlobId(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    private func isGroupControl(_ content: Relay_Content_Content) -> Bool {
        switch content.body {
        case .groupUpdate, .senderKeyDistribution: return true
        default: return false
        }
    }

    /// Mirrors `MessagingService.relayOfficialAccount`.
    public static let relayOfficialAccount = "relay.official"

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

        // The sender is whoever's session decrypted this: the certificate-
        // recovered identity for sealed messages, the session address otherwise.
        // A sender id inside the plaintext is only a claim — it must agree, or
        // any contact could pose as anyone (including us, via a fake sync copy).
        if !content.senderAccountID.isEmpty, content.senderAccountID != sender.name {
            throw EnvelopeProcessorError.senderSpoofed
        }
        let attestedAccount = sender.name
        // The official "Relay" notices chat is local-only; nothing arriving
        // over the network may land in it.
        if attestedAccount == Self.relayOfficialAccount {
            throw EnvelopeProcessorError.senderSpoofed
        }

        // Now that we know who really sent this (post-decrypt), drop it if the
        // sender is blocked. Sealed messages can't be filtered any earlier since
        // the wire envelope carries no sender.
        if blockedAccounts.contains(attestedAccount) {
            return ProcessedEnvelope(outcome: .ignored, peerAccount: attestedAccount)
        }

        // Group content is only accepted from current members of a group we
        // know. Group updates (handled, with their own authorization, by the
        // app) and sender-key distributions (harmless to store) are exempt.
        if let groupId, !isGroupControl(content) {
            guard let group = try? storage.messages.group(id: groupId),
                  attestedAccount == ownAccountId || group.members.contains(attestedAccount)
            else {
                log.warning("dropping group content from a non-member or for an unknown group")
                return ProcessedEnvelope(outcome: .ignored, peerAccount: attestedAccount)
            }
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

        // Edits and unsends name their target by timestamp only. Apply them only
        // to a message this sender actually wrote: their incoming message (in a
        // group, the one with their sender_account), or — for a sync copy from
        // our own other device — our outgoing message. Otherwise any peer or
        // group member could rewrite or delete someone else's message.
        func targetIsAuthoredBySender(timestamp: Int64, conversationId: String) -> Bool {
            let rows = (try? storage.database.query(
                "SELECT is_outgoing, sender_account FROM messages WHERE conversation_id = ? AND timestamp = ?",
                [.text(conversationId), .integer(timestamp)]
            )) ?? []
            return rows.contains { row in
                let outgoing = row[0].int64 == 1
                if isSyncMessage { return outgoing }
                if outgoing { return false }
                return groupId == nil || row[1].string == attestedAccount
            }
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
            // Relay blob ids are 32 lowercase hex chars. Anything else from a
            // peer is dropped: the id is later used in a request path and as a
            // cache file name.
            let attachments = text.attachments.filter { Self.isRelayBlobId($0.id) }.map { p in
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
            guard targetIsAuthoredBySender(timestamp: deletion.targetTimestamp, conversationId: conversationId) else {
                log.warning("ignoring unsend for a message the sender didn't write")
                return ProcessedEnvelope(outcome: .ignored, peerAccount: attestedAccount, conversationId: conversationId)
            }
            try storage.messages.markDeleted(conversationId: conversationId, targetTimestamp: deletion.targetTimestamp)
            return ProcessedEnvelope(outcome: .applied, peerAccount: attestedAccount, conversationId: conversationId)

        case .edit(let edit):
            let conversationId = try chatConversation()
            guard targetIsAuthoredBySender(timestamp: edit.targetTimestamp, conversationId: conversationId) else {
                log.warning("ignoring edit for a message the sender didn't write")
                return ProcessedEnvelope(outcome: .ignored, peerAccount: attestedAccount, conversationId: conversationId)
            }
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
                && Self.isRelayBlobId(profile.avatar.id)
                ? ProfileInfo.Avatar(id: profile.avatar.id, key: profile.avatar.key, digest: profile.avatar.digest)
                : nil
            let info = ProfileInfo(
                account: attestedAccount,
                displayName: profile.displayName,
                avatar: avatar,
                revision: profile.timestamp,
                status: profile.status,
                bio: profile.bio,
                links: profile.links.map { ProfileInfo.Link(label: $0.label, url: $0.url) }
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
            // Ephemeral — release the dedup claim. In a group, report the group's
            // existing conversation (never create one for a typing frame).
            try? storage.messages.releaseEnvelope(id: envelope.id)
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
            // Non-ephemeral (queues); the caller inserts the in-chat notice.
            let conversationId = try chatConversation()
            return ProcessedEnvelope(
                outcome: .applied, peerAccount: attestedAccount, conversationId: conversationId,
                screenshotAlert: ScreenshotAlertInfo(
                    conversationId: conversationId,
                    senderAccount: attestedAccount,
                    timestamp: shot.timestamp))

        case .screenSecurityUpdate(let upd):
            // 1:1 peer preference sync; the caller stores it as the peer's side.
            let conversationId = try chatConversation()
            return ProcessedEnvelope(
                outcome: .applied, peerAccount: attestedAccount, conversationId: conversationId,
                screenSecurityUpdate: ScreenSecurityInfo(
                    conversationId: conversationId,
                    senderAccount: attestedAccount,
                    enabled: upd.enabled,
                    timestamp: upd.timestamp))

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
        case .setScreenSecurity: .setScreenSecurity
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
