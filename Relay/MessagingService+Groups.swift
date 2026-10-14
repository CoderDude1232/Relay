//
//  MessagingService+Groups.swift
//  Relay
//
//  Group invites, sending to groups, applying group updates, admins, and
//  group read receipts.
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
    /// Decrypts an invite for preview; stores nothing and contacts no member.
    /// `fragment` is the base64url key||digest from the link's fragment.
    func previewGroupInvite(token: String, fragment: String) async throws -> GroupInvitePreview {
        guard let keyDigest = Data(base64URLEncoded: fragment), keyDigest.count == 64 else {
            throw RelayAPIError.malformedResponse
        }
        let blob = try await api.claimEncryptedGroupInvite(token: token)
        let json = try AttachmentCipher.open(
            blob, key: Data(keyDigest.prefix(32)), digest: Data(keyDigest.suffix(32))
        )
        let payload = try JSONDecoder().decode(GroupInvitePayload.self, from: json)
        guard Self.isValidGroupId(payload.groupId, ownAccount: credentials.accountId) else {
            throw GroupError.notFound
        }
        var preview = GroupInvitePreview(groupName: ProfileText.groupName(payload.name), memberCount: payload.members.count, payload: json)
        if let existing = try storage.messages.group(id: payload.groupId),
           existing.members.contains(credentials.accountId) {
            preview.existingConversationId = try storage.messages.groupConversationId(groupId: payload.groupId)
        }
        return preview
    }

    /// Announces the join with the invite capability echoed, so a non-admin
    /// self-add is accepted.
    func acceptGroupInvite(_ preview: GroupInvitePreview) async throws -> String {
        let payload = try JSONDecoder().decode(GroupInvitePayload.self, from: preview.payload)
        guard Self.isValidGroupId(payload.groupId, ownAccount: credentials.accountId) else {
            throw GroupError.notFound
        }
        // Already a member: the invite's snapshot is older than our state and
        // could restore members removed since the link was made.
        if let existing = try storage.messages.group(id: payload.groupId),
           existing.members.contains(credentials.accountId) {
            return try storage.messages.groupConversationId(groupId: payload.groupId) ?? ""
        }

        var members = payload.members
        if !members.contains(credentials.accountId) { members.append(credentials.accountId) }
        setGroupInviteKey(payload.groupId, payload.inviteKey)
        try storage.messages.upsertGroup(
            id: payload.groupId, name: payload.name, distributionId: payload.distributionId,
            revision: max(1, min(payload.revision ?? 1, 1_000_000_000)), members: members,
            // Keep the group's real admins; an empty list would make every
            // member an admin from this device's point of view.
            admins: (payload.admins ?? []).filter { payload.members.contains($0) }
        )
        refreshConversations()
        for member in payload.members where member != credentials.accountId {
            try? await refreshSessions(withPeer: member)
        }
        if let stored = try storage.messages.group(id: payload.groupId) {
            try? await distributeSenderKeyIfNeeded(group: stored)
            var join = Relay_Content_GroupUpdate()
            join.action = .add
            join.target = credentials.accountId
            await sendGroupUpdateCustom(join, group: stored)
        }
        insertSystemLine("You joined via invite link", inGroup: payload.groupId)
        if let stored = try storage.messages.group(id: payload.groupId) {
            await distributeProfileToGroupMembersIfNeeded(group: stored)
        }
        return try storage.messages.groupConversationId(groupId: payload.groupId) ?? ""
    }

    func leaveGroup(_ groupId: String) async throws {
        guard let existing = try storage.messages.group(id: groupId) else { throw GroupError.notFound }
        // Stop sharing our location with a group we're leaving.
        if let convId = try? storage.messages.groupConversationId(groupId: groupId) {
            LocationShareManager.shared.stop(in: convId)
        }
        let remaining = existing.members.filter { $0 != credentials.accountId }
        let announce = StoredGroup(
            id: existing.id, name: existing.name, distributionId: existing.distributionId,
            revision: existing.revision + 1, members: remaining,
            admins: existing.admins.filter { $0 != credentials.accountId },
            isAnnounceOnly: existing.isAnnounceOnly
        )
        await sendGroupUpdate(.leave, group: announce, target: credentials.accountId)
        try storage.messages.upsertGroup(
            id: groupId, name: existing.name, distributionId: existing.distributionId,
            revision: existing.revision + 1, members: remaining,
            admins: existing.admins.filter { $0 != credentials.accountId },
            isAnnounceOnly: existing.isAnnounceOnly
        )
        refreshConversations()
        insertSystemLine("You left", inGroup: groupId)
    }

    func distributeProfileToGroupMembersIfNeeded(group: StoredGroup) async {
        if conversations.first(where: { $0.groupId == group.id })?.isRequest == true { return }
        let needsProfile = group.members.filter {
            $0 != credentials.accountId && profileNeedsSending(to: $0)
        }
        for member in needsProfile {
            await sendMyProfileIfNeeded(toPeer: member)
        }
    }

    /// One member failing doesn't stop the others. Reached members are recorded
    /// per message so a retry doesn't duplicate.
    func transmitToGroup(
        _ content: Relay_Content_Content, group: StoredGroup, messageId: String, timestamp: Int64
    ) async throws {
        try await distributeSenderKeyIfNeeded(group: group)
        await distributeProfileToGroupMembersIfNeeded(group: group)

        let deliveredKey = "groupsent:\(messageId)"
        var delivered = Set(loadStringArray(deliveredKey))
        let targets = group.members.filter { $0 != credentials.accountId && !delivered.contains($0) }
        var firstError: Error?
        if sealedSenderEnabled {
            // Encrypt once with the sender key, then seal that ciphertext per
            // device: the relay still learns neither the sender nor that these
            // deliveries are one group send. A member we can't reach this way
            // (no access key, missing identity, stale mailbox) gets the
            // pairwise send instead.
            let payload = try content.serializedData()
            let fastPath = try? await sealedGroupFanOut(payload, group: group, members: targets, timestamp: timestamp)
            for member in targets {
                if fastPath?.contains(member) == true {
                    delivered.insert(member)
                    continue
                }
                do {
                    try await sendContent(payload, toPeer: member, clientTimestamp: timestamp)
                    delivered.insert(member)
                } catch {
                    firstError = firstError ?? error
                }
            }
        } else {
            // Encrypt once with the sender key; fan out the same ciphertext.
            guard let distributionId = UUID(uuidString: group.distributionId) else { throw GroupError.notFound }
            let sealed = try engine.groupEncrypt(try ContentPadding.pad(content.serializedData()), distributionId: distributionId)
            for member in targets {
                do {
                    try await sendEncrypted(sealed, toPeer: member, clientTimestamp: timestamp)
                    delivered.insert(member)
                } catch {
                    firstError = firstError ?? error
                }
            }
        }
        if let firstError {
            saveStringArray(deliveredKey, Array(delivered))
            throw firstError
        }
        try? storage.database.run("DELETE FROM kv WHERE key = ?", [.text(deliveredKey)])
    }

    /// Sealed-sender group fan-out (see CryptoEngine.sealedGroupEncrypt).
    /// Returns the members every device of whom accepted the message.
    private func sealedGroupFanOut(
        _ payload: Data, group: StoredGroup, members: [String], timestamp: Int64
    ) async throws -> Set<String> {
        guard let distributionId = UUID(uuidString: group.distributionId), !members.isEmpty else { return [] }
        let certificate = try await senderCertificate()
        var routes: [(member: String, mailbox: String, accessKey: Data, address: ProtocolAddress)] = []
        var skipped = Set<String>()
        for member in members {
            do {
                if knownAccessKey(member) == nil { try await refreshSessions(withPeer: member) }
                guard let accessKey = knownAccessKey(member) else { skipped.insert(member); continue }
                let devices = try await knownMailboxDevices(ofPeer: member)
                guard !devices.isEmpty else { skipped.insert(member); continue }
                for device in devices {
                    guard let mailbox = device.mailboxId, !mailbox.isEmpty else { skipped.insert(member); continue }
                    let address = try ProtocolAddress(name: member, deviceId: device.id)
                    guard try engine.hasSession(with: address) else { skipped.insert(member); continue }
                    routes.append((member, mailbox, accessKey, address))
                }
            } catch {
                skipped.insert(member)
            }
        }
        routes.removeAll { skipped.contains($0.member) }
        guard !routes.isEmpty else { return [] }

        let blobs = try engine.sealedGroupEncrypt(
            try ContentPadding.pad(payload), distributionId: distributionId,
            senderCertificate: certificate, recipients: routes.map(\.address)
        )
        var failed = skipped
        for (route, blob) in zip(routes, blobs) where !failed.contains(route.member) {
            do {
                _ = try await api.sendSealed(
                    mailboxId: route.mailbox, type: .message, content: blob,
                    accessKey: route.accessKey, ephemeral: false, clientTimestamp: timestamp
                )
            } catch {
                failed.insert(route.member)
            }
        }
        // A member with a failed device falls back to the pairwise path, which
        // re-sends to all of their devices; duplicates are dropped by id.
        return Set(routes.map(\.member)).subtracting(failed)
    }

    /// Sends our SKDM to members who lack it for the current distribution id,
    /// and again when a member's device list changes (a new device has no
    /// sender key yet). Tracked in kv as "member:deviceIds" per epoch.
    func distributeSenderKeyIfNeeded(group: StoredGroup) async throws {
        guard let distributionId = UUID(uuidString: group.distributionId) else { return }
        let key = "skdm:\(group.id):\(group.distributionId)"
        let deviceKey: (String) -> String = { member in
            member + ":" + self.knownDevices(ofPeer: member).map { String($0.id) }.sorted().joined(separator: ",")
        }
        var sent = Set(loadStringArray(key))
        let targets = group.members.filter { $0 != credentials.accountId && !sent.contains(deviceKey($0)) }
        guard !targets.isEmpty else { return }

        let skdm = try engine.senderKeyDistributionMessage(distributionId: distributionId)
        var content = Relay_Content_Content()
        content.senderKeyDistribution.data = skdm
        content.senderKeyDistribution.distributionID = group.distributionId
        content.groupID = group.id
        let data = try content.serializedData()
        for member in targets {
            do {
                try await sendContent(data, toPeer: member, clientTimestamp: Int64(Date().timeIntervalSince1970 * 1000))
                sent.insert(deviceKey(member))
            } catch {
                log.warning("SKDM send failed: \(PrivacyRedactor.error(error))")
            }
        }
        saveStringArray(key, Array(sent))
    }

    func sendGroupUpdate(_ action: Relay_Content_GroupUpdate.Action, group: StoredGroup, target: String) async {
        var update = Relay_Content_GroupUpdate()
        update.action = action
        update.target = target
        await sendGroupUpdateCustom(update, group: group)
    }

    static func randomInviteKey() -> Data {
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return key
    }

    /// A group id must be a random UUID that can't be mistaken for an account:
    /// group and 1:1 conversations share one key space.
    static func isValidGroupId(_ id: String, ownAccount: String) -> Bool {
        UUID(uuidString: id) != nil && id != ownAccount && id != relayOfficialAccount
    }

    func sendGroupUpdateCustom(
        _ update: Relay_Content_GroupUpdate, group: StoredGroup,
        to recipients: [String]? = nil, includeInviteKey: Bool = true
    ) async {
        var u = update
        u.actor = credentials.accountId
        u.name = group.name
        u.revision = group.revision
        // Full roster, admins and epoch: there is no server-side group state.
        u.members = group.members
        u.admins = group.admins
        u.distributionID = group.distributionId
        if includeInviteKey, let inviteKey = groupInviteKey(group.id) { u.inviteKey = inviteKey }
        var content = Relay_Content_Content()
        content.groupUpdate = u
        content.groupID = group.id
        content.senderAccountID = credentials.accountId
        content.senderDeviceID = credentials.deviceId
        guard let data = try? content.serializedData() else { return }
        for member in recipients ?? group.members where member != credentials.accountId {
            try? await sendContent(data, toPeer: member, clientTimestamp: Int64(Date().timeIntervalSince1970 * 1000))
        }
    }

    /// Fans pre-encrypted ciphertext (e.g. sender-key) to every device of
    /// `account`, with the same mismatch retry as 1:1 sends.
    private func sendEncrypted(_ message: SecureMessage, toPeer account: String, clientTimestamp: Int64) async throws {
        guard socket != nil else { throw RelayWebSocketError.notConnected }
        try requireAcknowledgedIdentity(forPeer: account)
        var devices = try await knownMailboxDevices(ofPeer: account)
        func payloads(for devices: [PeerDevice]) -> [(mailboxId: String, payload: DeviceMessagePayload)] {
            devices.compactMap { device in
                guard let mailboxId = device.mailboxId, !mailboxId.isEmpty else { return nil }
                return (
                    mailboxId,
                    DeviceMessagePayload(deviceId: device.id, registrationId: device.registrationId, message: message)
                )
            }
        }
        let firstRoundIds = Set(devices.map { $0.id })
        var outcome = try await sendMailboxPayloads(payloads(for: devices), clientTimestamp: clientTimestamp)
        if case .mismatchedDevices(let missing, _, let stale) = outcome {
            try await refreshSessions(withPeer: account)
            try requireAcknowledgedIdentity(forPeer: account)
            devices = try await knownMailboxDevices(ofPeer: account)
            let retryIds = Set(missing).subtracting(firstRoundIds).union(Set(stale))
            if !retryIds.isEmpty {
                let retryDevices = devices.filter { retryIds.contains($0.id) }
                outcome = try await sendMailboxPayloads(payloads(for: retryDevices), clientTimestamp: clientTimestamp)
                if case .mismatchedDevices(let m2, let e2, let s2) = outcome, e2.isEmpty {
                    let allAddressedIds = firstRoundIds.union(retryIds)
                    if Set(m2 + s2).isSubset(of: allAddressedIds) {
                        outcome = .ok(serverTimestamp: 0)
                    }
                }
            } else {
                outcome = .ok(serverTimestamp: 0)
            }
        }
        guard case .ok = outcome else {
            throw RelayAPIError.http(status: 0, message: "group send rejected: \(outcome)")
        }
    }

    /// `authenticatedSender` is the identity proven by decryption (sealed-sender
    /// certificate or ratchet) and is the source of truth for authorization.
    func handleGroupUpdate(_ info: GroupUpdateInfo, authenticatedSender: String?) async {
        let existing = try? storage.messages.group(id: info.groupId)

        // 1. The claimed `actor` must be the authenticated sender.
        if let sender = authenticatedSender, !sender.isEmpty, !info.actor.isEmpty, info.actor != sender {
            log.warning("group update: actor != authenticated sender; dropping")
            return
        }
        let actor = (authenticatedSender.flatMap { $0.isEmpty ? nil : $0 }) ?? info.actor
        guard !actor.isEmpty else { return }
        // A sender whose safety number changed and hasn't been accepted can't
        // change the group: a relay posing as an admin would start here.
        guard actor == credentials.accountId || IdentityAcknowledgement.isSettled(peer: actor, storage: storage) else {
            log.warning("group update from an unaccepted safety number; dropping")
            return
        }
        // Revisions only ever step by one per change; an implausible jump would
        // overflow our own `revision + 1` later and wedge every admin action.
        guard info.revision >= 0, info.revision <= (existing?.revision ?? 0) + 100_000 else {
            log.warning("group update: implausible revision; dropping")
            return
        }

        // 2. Authorization. With no local state, trust the authenticated actor
        //    adding us. Otherwise only admins change group state, any member may
        //    leave, and a link-joiner may add only themselves by echoing the
        //    current invite capability. Legacy groups with no admins are open.
        let isBootstrap = (existing == nil)
        if isBootstrap {
            // Only accept a brand-new group from someone who is in it, that
            // includes us, and whose id can't collide with a 1:1 chat.
            guard Self.isValidGroupId(info.groupId, ownAccount: credentials.accountId),
                  info.members.contains(actor),
                  info.members.contains(credentials.accountId),
                  info.action == .create || info.action == .add
            else {
                log.warning("group update: rejected bootstrap for unknown group")
                return
            }
        }
        let actorIsAdmin = existing.map { Self.isGroupAdmin(actor, in: $0) } ?? true
        let wasMember = existing?.members.contains(credentials.accountId) ?? false
        let isSelfDeparture = (info.action == .leave || info.action == .remove) && info.target == actor
            && (existing?.members.contains(actor) ?? false)
        let isValidSelfJoin = info.action == .add && info.target == actor
            && !info.inviteKey.isEmpty && groupInviteKey(info.groupId) == info.inviteKey
        guard isBootstrap || actorIsAdmin || isSelfDeparture || isValidSelfJoin else {
            log.warning("group update: \(String(describing: info.action)) from non-admin; dropping")
            return
        }
        // An admin change older than what we have (delayed or replayed) would
        // roll the roster back, e.g. re-adding someone since removed.
        if let existing, !isSelfDeparture, !isValidSelfJoin, info.revision < existing.revision {
            log.warning("group update: stale revision; dropping")
            return
        }

        // Store the invite capability only from authorized senders, never from
        // a self-join echo.
        if !info.inviteKey.isEmpty, isBootstrap || actorIsAdmin {
            setGroupInviteKey(info.groupId, info.inviteKey)
        }
        // Silent capability broadcast: nothing else to apply.
        if info.action == .unknown { return }

        // 3. We were removed by an admin.
        if info.action == .remove, info.target == credentials.accountId, let existing {
            do {
                try storage.messages.upsertGroup(
                    id: info.groupId, name: existing.name, distributionId: existing.distributionId,
                    revision: max(info.revision, existing.revision),
                    members: existing.members.filter { $0 != credentials.accountId },
                    admins: existing.admins
                )
                refreshConversations()
                if let line = systemLine(for: info) { insertSystemLine(line, inGroup: info.groupId) }
            } catch { log.warning("group remove(self) failed: \(PrivacyRedactor.error(error))") }
            return
        }

        // 4. Metadata-only actions carry their payload directly.
        switch info.action {
        case .describe:
            do {
                try storage.messages.setGroupDescription(id: info.groupId, description: info.description)
                refreshConversations()
                if let line = systemLine(for: info) { insertSystemLine(line, inGroup: info.groupId) }
            } catch { log.warning("group description update failed: \(PrivacyRedactor.error(error))") }
            return
        case .avatar where !info.avatarId.isEmpty:
            Task {
                do {
                    let ciphertext = try await api.downloadAttachment(id: info.avatarId)
                    let opened = try AttachmentCipher.open(ciphertext, key: info.avatarKey, digest: info.avatarDigest)
                    guard let data = SafeImage.avatarJPEG(from: opened) else { return }
                    if SensitiveContent.isRestricted, await SensitiveContent.isSensitive(imageData: data) { return }
                    try storage.messages.setGroupAvatar(id: info.groupId, avatarData: data)
                    refreshConversations()
                } catch { log.warning("group avatar download failed: \(PrivacyRedactor.error(error))") }
            }
            return
        case .promoteAdmin, .demoteAdmin:
            // An empty admin list would make every member an admin; a group
            // with admins never goes back to that.
            if info.admins.isEmpty, !(existing?.admins.isEmpty ?? true) {
                log.warning("group update: refusing an empty admin list")
                return
            }
            do {
                try storage.messages.setGroupAdmins(id: info.groupId, admins: info.admins)
                refreshConversations()
                if let line = systemLine(for: info) { insertSystemLine(line, inGroup: info.groupId) }
            } catch { log.warning("group admin update failed: \(PrivacyRedactor.error(error))") }
            return
        case .setAnnounceOnly:
            do {
                try storage.messages.setGroupAnnounceOnly(id: info.groupId, isAnnounceOnly: info.announceOnly)
                refreshConversations()
                if let line = systemLine(for: info) { insertSystemLine(line, inGroup: info.groupId) }
            } catch { log.warning("group announce-only update failed: \(PrivacyRedactor.error(error))") }
            return
        case .setScreenSecurity:
            do {
                try storage.messages.setGroupScreenSecurity(id: info.groupId, enabled: info.screenSecurity)
                refreshConversations()
                if let line = systemLine(for: info) { insertSystemLine(line, inGroup: info.groupId) }
            } catch { log.warning("group screen-security update failed: \(PrivacyRedactor.error(error))") }
            return
        default:
            break
        }

        // 5. Roster actions (create/add/remove/leave/rename).
        let newMembers: [String]
        let newAdmins: [String]
        let newName: String
        let distributionId: String
        if isSelfDeparture, let existing {
            // Never adopt the sender's lists here: self-departure bypasses the
            // admin check, so that would let any member make themselves sole
            // admin and reroute the group.
            newMembers = existing.members.filter { $0 != actor }
            var admins = existing.admins.filter { $0 != actor }
            // The last admin left: the same remaining member becomes admin on
            // every device, rather than the group falling open to everyone.
            if admins.isEmpty, !existing.admins.isEmpty, let heir = newMembers.sorted().first {
                admins = [heir]
            }
            newAdmins = admins
            newName = existing.name
            distributionId = existing.distributionId
        } else if isBlocked(actor), let existing {
            // A blocked admin gets this far only for someone else's removal
            // (see EnvelopeProcessor): apply just that, never their lists.
            newMembers = existing.members.filter { $0 != info.target }
            newAdmins = existing.admins.filter { $0 != info.target }
            newName = existing.name
            distributionId = info.distributionId.isEmpty ? existing.distributionId : info.distributionId
        } else if isValidSelfJoin && !isBootstrap && !actorIsAdmin, let existing {
            // A link-joiner may only add themselves; never take a non-admin's
            // roster, admins, name or epoch.
            newMembers = existing.members.contains(actor) ? existing.members : existing.members + [actor]
            newAdmins = existing.admins
            newName = existing.name
            distributionId = existing.distributionId
        } else {
            // Authorized sender: trust the full lists, falling back to the delta
            // when only a target is given.
            var members = info.members.isEmpty ? (existing?.members ?? []) : info.members
            if info.members.isEmpty {
                switch info.action {
                case .add where !info.target.isEmpty:
                    if !members.contains(info.target) { members.append(info.target) }
                case .remove, .leave:
                    members.removeAll { $0 == info.target }
                default:
                    break
                }
            }
            newMembers = members
            newAdmins = (info.admins.isEmpty ? (existing?.admins ?? [actor]) : info.admins)
                .filter { newMembers.contains($0) }
            newName = info.name.isEmpty ? (existing?.name ?? "") : info.name
            // Adopt a rotated epoch so our next send uses a key a removed member
            // can't read.
            distributionId = !info.distributionId.isEmpty
                ? info.distributionId
                : (existing?.distributionId ?? UUID().uuidString)
        }
        do {
            try storage.messages.upsertGroup(
                id: info.groupId, name: newName, distributionId: distributionId,
                // A leave or link join bypasses the admin check, so it never
                // moves the revision (an inflated one would make every later
                // admin change look stale here).
                revision: (isSelfDeparture || (isValidSelfJoin && !actorIsAdmin))
                    ? (existing?.revision ?? 0)
                    : max(info.revision, existing?.revision ?? 0),
                members: newMembers, admins: newAdmins
            )
            // Added by someone we've never chatted with to a group we weren't in
            // (new, or one we left or deleted as a request): a request.
            if !wasMember, actor != credentials.accountId, !hasAcceptedChat(with: actor),
               let convoId = try? storage.messages.groupConversationId(groupId: info.groupId) {
                try? storage.messages.setConversationAccepted(convoId, accepted: false)
                // Block and Report on the request act on whoever added us.
                try? storage.database.run("INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
                                          [.text(Self.groupAddedByKey(info.groupId)), .blob(Data(actor.utf8))])
            }
            refreshConversations()
            if let convoId = try? storage.messages.groupConversationId(groupId: info.groupId) {
                refreshActiveMessages(ifShowing: convoId)
            }
            // Names arrive via profiles and certificates, never a relay lookup.
            if newMembers.contains(credentials.accountId),
               let stored = try? storage.messages.group(id: info.groupId) {
                await distributeProfileToGroupMembersIfNeeded(group: stored)
            }
            if let line = systemLine(for: info) { insertSystemLine(line, inGroup: info.groupId) }
            // Non-sealed groups use sender keys: share ours with new members and
            // mint a fresh one after an epoch rotation.
            if !sealedSenderEnabled, newMembers.contains(credentials.accountId),
               let stored = try? storage.messages.group(id: info.groupId) {
                try? await distributeSenderKeyIfNeeded(group: stored)
            }
        } catch {
            log.warning("group update failed: \(PrivacyRedactor.error(error))")
        }
    }

    private func systemLine(for info: GroupUpdateInfo) -> String? {
        let actor = displayName(forAccount: info.actor)
        switch info.action {
        case .create: return "\(actor) created the group"
        case .add: return "\(actor) added \(displayName(forAccount: info.target))"
        case .remove: return "\(actor) removed \(displayName(forAccount: info.target))"
        case .leave: return "\(actor) left"
        case .rename: return "\(actor) renamed the group to \"\(info.name)\""
        case .describe: return "\(actor) updated the group description"
        case .avatar: return "\(actor) updated the group photo"
        case .promoteAdmin: return "\(actor) made \(displayName(forAccount: info.target)) an admin"
        case .demoteAdmin: return "\(actor) removed \(displayName(forAccount: info.target)) as admin"
        case .setAnnounceOnly: return info.announceOnly
            ? "\(actor) turned on announce-only mode"
            : "\(actor) turned off announce-only mode"
        case .setScreenSecurity: return info.screenSecurity
            ? "\(actor) turned on screenshot protection"
            : "\(actor) turned off screenshot protection"
        case .unknown: return nil
        }
    }

    // MARK: - Admin management

    func promoteAdmin(in groupId: String, account: String) async throws {
        guard let existing = try storage.messages.group(id: groupId) else { throw GroupError.notFound }
        try requireGroupAdmin(existing)
        let admins = existing.admins.contains(account) ? existing.admins : existing.admins + [account]
        try storage.messages.setGroupAdmins(id: groupId, admins: admins)
        guard let grp = try? storage.messages.group(id: groupId) else { return }
        var update = Relay_Content_GroupUpdate()
        update.action = .promoteAdmin
        update.target = account
        update.admins = admins
        await sendGroupUpdateCustom(update, group: grp)
        insertSystemLine("\(displayName(forAccount: credentials.accountId)) made \(displayName(forAccount: account)) an admin", inGroup: groupId)
        refreshConversations()
    }

    func demoteAdmin(in groupId: String, account: String) async throws {
        guard let existing = try storage.messages.group(id: groupId) else { throw GroupError.notFound }
        try requireGroupAdmin(existing)
        let admins = existing.admins.filter { $0 != account }
        try storage.messages.setGroupAdmins(id: groupId, admins: admins)
        guard let grp = try? storage.messages.group(id: groupId) else { return }
        var update = Relay_Content_GroupUpdate()
        update.action = .demoteAdmin
        update.target = account
        update.admins = admins
        await sendGroupUpdateCustom(update, group: grp)
        insertSystemLine("\(displayName(forAccount: credentials.accountId)) removed \(displayName(forAccount: account)) as admin", inGroup: groupId)
        refreshConversations()
    }

    func setAnnounceOnly(_ enabled: Bool, in groupId: String) async throws {
        guard let existing = try storage.messages.group(id: groupId) else { throw GroupError.notFound }
        try requireGroupAdmin(existing)
        try storage.messages.setGroupAnnounceOnly(id: groupId, isAnnounceOnly: enabled)
        guard let grp = try? storage.messages.group(id: groupId) else { return }
        var update = Relay_Content_GroupUpdate()
        update.action = .setAnnounceOnly
        update.announceOnly = enabled
        await sendGroupUpdateCustom(update, group: grp)
        let line = enabled ? "You turned on announce-only mode" : "You turned off announce-only mode"
        insertSystemLine(line, inGroup: groupId)
        refreshConversations()
    }

    func isAdmin(in conversationId: String) -> Bool {
        guard let grp = group(for: conversationId) else { return false }
        return grp.admins.contains(credentials.accountId)
    }

    func isAnnounceOnly(conversationId: String) -> Bool {
        group(for: conversationId)?.isAnnounceOnly ?? false
    }

    // MARK: - Group receipt display

    /// Read when every other member has read it, delivered when all have
    /// received it, otherwise the message's own status.
    func groupAggregateStatus(for message: StoredMessage, in conversationId: String) -> MessageStatus {
        // Cached group avoids DB queries per message during render.
        guard message.isOutgoing, let group = cachedActiveGroup ?? group(for: conversationId)
        else { return message.status }
        let recipients = group.members.filter { $0 != credentials.accountId }
        guard !recipients.isEmpty else { return message.status }
        let receipts = (try? storage.messages.groupReceipts(
            conversationId: conversationId, messageTimestamp: message.timestamp)) ?? [:]
        let read = recipients.filter { receipts[$0] == .read }.count
        let delivered = recipients.filter { receipts[$0] == .read || receipts[$0] == .delivered }.count
        if read == recipients.count { return .read }
        if delivered == recipients.count { return .delivered }
        return message.status
    }

    /// For the info sheet, sorted read-first.
    func groupReadReceipts(for message: StoredMessage, in conversationId: String) -> [(name: String, status: String)] {
        guard let group = group(for: conversationId) else { return [] }
        let recipients = group.members.filter { $0 != credentials.accountId }
        let receipts = (try? storage.messages.groupReceipts(
            conversationId: conversationId, messageTimestamp: message.timestamp)) ?? [:]
        func rank(_ s: MessageStatus?) -> Int { s == .read ? 0 : (s == .delivered ? 1 : 2) }
        func label(_ s: MessageStatus?) -> String { s == .read ? "Read" : (s == .delivered ? "Delivered" : "Sent") }
        return recipients
            .map { (account: $0, status: receipts[$0]) }
            .sorted { (rank($0.status), displayName(forAccount: $0.account)) < (rank($1.status), displayName(forAccount: $1.account)) }
            .map { (name: displayName(forAccount: $0.account), status: label($0.status)) }
    }
}
