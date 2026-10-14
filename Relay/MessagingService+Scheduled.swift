//
//  MessagingService+Scheduled.swift
//  Relay
//
//  Draft persistence, the shared notepad, and scheduled messages.
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
    // MARK: - Draft persistence

    func readDraft(for conversationId: String) -> String {
        let key = "draft:\(conversationId)"
        return (try? storage.database.query(
            "SELECT value FROM kv WHERE key = ?", [.text(key)]
        ).first?.first?.data).flatMap { $0 }.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
    }

    func saveDraft(_ text: String, for conversationId: String) {
        let key = "draft:\(conversationId)"
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? storage.database.run("DELETE FROM kv WHERE key = ?", [.text(key)])
        } else {
            try? storage.database.run(
                "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
                [.text(key), .blob(Data(text.utf8))]
            )
        }
    }

    // MARK: - Shared notepad

    func notepadContent(for conversationId: String) -> String {
        let key = "notepad:\(conversationId)"
        return (try? storage.database.query(
            "SELECT value FROM kv WHERE key = ?", [.text(key)]
        ).first?.first?.data).flatMap { $0 }.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
    }

    func setNotepadContent(_ content: String, for conversationId: String) {
        let key = "notepad:\(conversationId)"
        try? storage.database.run(
            "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
            [.text(key), .blob(Data(content.utf8))]
        )
    }

    func sendNotepadUpdate(_ content: String, in conversationId: String) async {
        let body = notepadPrefix + content
        await sendMessage(body, in: conversationId)
        setNotepadContent(content, for: conversationId)
    }

    // MARK: - Scheduled messages

    struct ScheduledMessage: Codable, Identifiable {
        let id: String
        let conversationId: String
        let body: String
        let scheduledAt: Double  // Unix timestamp (seconds)
    }

    func scheduleMessage(_ body: String, in conversationId: String, at date: Date) {
        let msg = ScheduledMessage(
            id: UUID().uuidString,
            conversationId: conversationId,
            body: body,
            scheduledAt: date.timeIntervalSince1970
        )
        guard let data = try? JSONEncoder().encode(msg) else { return }
        try? storage.database.run(
            "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
            [.text("sched:\(msg.id)"), .blob(data)]
        )
    }

    func scheduledMessages() -> [ScheduledMessage] {
        let rows = (try? storage.database.query(
            "SELECT value FROM kv WHERE key LIKE 'sched:%'"
        )) ?? []
        return rows.compactMap { row -> ScheduledMessage? in
            guard let data = row.first?.data else { return nil }
            return try? JSONDecoder().decode(ScheduledMessage.self, from: data)
        }.sorted { $0.scheduledAt < $1.scheduledAt }
    }

    func cancelScheduled(id: String) {
        try? storage.database.run("DELETE FROM kv WHERE key = ?", [.text("sched:\(id)")])
    }

    func flushDueScheduledMessages() async {
        let now = Date().timeIntervalSince1970
        let due = scheduledMessages().filter { $0.scheduledAt <= now }
        for msg in due {
            cancelScheduled(id: msg.id)
            await sendMessage(msg.body, in: msg.conversationId)
        }
    }

    func insertSystemLine(_ text: String, inGroup groupId: String) {
        guard let conversationId = (try? storage.messages.groupConversationId(groupId: groupId)) ?? nil else { return }
        insertSystemLine(text, conversationId: conversationId)
    }

    func insertSystemLine(_ text: String, conversationId: String) {
        _ = try? storage.messages.insertMessage(
            id: UUID().uuidString, conversationId: conversationId, isOutgoing: false,
            body: text, timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            status: .received, senderAccount: Self.systemSender
        )
        refreshConversations()
        refreshActiveMessages(ifShowing: conversationId)
    }

    func groupForConversation(_ conversationId: String) throws -> StoredGroup? {
        guard let groupId = try storage.database.query(
            "SELECT group_id FROM conversations WHERE id = ?", [.text(conversationId)]
        ).first?.first?.string else { return nil }
        return try storage.messages.group(id: groupId)
    }

    /// Legacy groups with no recorded admins are open to every member.
    func requireGroupAdmin(_ group: StoredGroup) throws {
        guard Self.isGroupAdmin(credentials.accountId, in: group) else {
            throw GroupError.notAdmin
        }
    }

    /// An admin must be a current member. Legacy groups with no admin list
    /// treat every member, and only members, as admins.
    static func isGroupAdmin(_ account: String, in group: StoredGroup) -> Bool {
        guard group.members.contains(account) else { return false }
        return group.admins.isEmpty || group.admins.contains(account)
    }

    /// Groups are entirely client-side; the relay never learns a group exists,
    /// its name or its members. Returns the conversation id.
    func createGroup(name: String, memberUsernames: [String]) async throws -> String {
        var members: [String] = [credentials.accountId]
        for username in memberUsernames {
            let account = try await resolveAccount(username: username)
            if !members.contains(account) { members.append(account) }
            try? await refreshSessions(withPeer: account) // pairwise sessions for SKDM/control
        }
        let groupId = UUID().uuidString
        let distributionId = UUID().uuidString
        try storage.messages.upsertGroup(
            id: groupId, name: name, distributionId: distributionId, revision: 1,
            members: members, admins: [credentials.accountId]
        )
        refreshConversations()
        if let stored = try storage.messages.group(id: groupId) {
            try? await distributeSenderKeyIfNeeded(group: stored)
            await sendGroupUpdate(.create, group: stored, target: "")
        }
        insertSystemLine("You created \"\(name)\"", inGroup: groupId)
        if let stored = try storage.messages.group(id: groupId) {
            await distributeProfileToGroupMembersIfNeeded(group: stored)
        }
        return try storage.messages.groupConversationId(groupId: groupId) ?? ""
    }

    func addGroupMember(username: String, toGroup groupId: String) async throws {
        let account = try await resolveAccount(username: username)
        try? await refreshSessions(withPeer: account)
        guard let existing = try storage.messages.group(id: groupId) else { throw GroupError.notFound }
        try requireGroupAdmin(existing)
        var members = existing.members
        if !members.contains(account) { members.append(account) }
        try storage.messages.upsertGroup(
            id: groupId, name: existing.name, distributionId: existing.distributionId,
            revision: existing.revision + 1, members: members, admins: existing.admins,
            isAnnounceOnly: existing.isAnnounceOnly
        )
        refreshConversations()
        if let stored = try storage.messages.group(id: groupId) {
            try? await distributeSenderKeyIfNeeded(group: stored)
            await sendGroupUpdate(.add, group: stored, target: account)
        }
        insertSystemLine("You added \(username)", inGroup: groupId)
    }

    func removeGroupMember(_ account: String, fromGroup groupId: String) async throws {
        guard let existing = try storage.messages.group(id: groupId) else { throw GroupError.notFound }
        try requireGroupAdmin(existing)
        let members = existing.members.filter { $0 != account }
        // Rotate the sender-key epoch so the removed member can't read future
        // messages: a new distribution id makes every member mint a new key.
        let newDistributionId = UUID().uuidString
        try storage.messages.upsertGroup(
            id: groupId, name: existing.name, distributionId: newDistributionId,
            revision: existing.revision + 1, members: members,
            admins: existing.admins.filter { $0 != account }, isAnnounceOnly: existing.isAnnounceOnly
        )
        // The removed member knows the invite capability; replace it so they
        // can't rejoin.
        if groupInviteKey(groupId) != nil {
            setGroupInviteKey(groupId, Self.randomInviteKey())
        }
        refreshConversations()
        if let stored = try storage.messages.group(id: groupId) {
            try? await distributeSenderKeyIfNeeded(group: stored)
            await sendGroupUpdate(.remove, group: stored, target: account)
            // Tell the removed member too, without the new invite key.
            var notice = Relay_Content_GroupUpdate()
            notice.action = .remove
            notice.target = account
            await sendGroupUpdateCustom(notice, group: stored, to: [account], includeInviteKey: false)
        }
        insertSystemLine("You removed \(displayName(forAccount: account))", inGroup: groupId)
    }

    func renameGroup(groupId: String, name: String) async throws {
        guard let existing = try storage.messages.group(id: groupId) else { throw GroupError.notFound }
        try requireGroupAdmin(existing)
        try storage.messages.upsertGroup(
            id: groupId, name: name, distributionId: existing.distributionId,
            revision: existing.revision + 1, members: existing.members,
            admins: existing.admins, isAnnounceOnly: existing.isAnnounceOnly
        )
        refreshConversations()
        if let stored = try storage.messages.group(id: groupId) {
            var update = Relay_Content_GroupUpdate()
            update.action = .rename
            update.name = name
            await sendGroupUpdateCustom(update, group: stored)
        }
        insertSystemLine("You renamed the group to \"\(name)\"", inGroup: groupId)
    }

    func setGroupDescription(_ description: String, groupId: String) async throws {
        guard let existing = try storage.messages.group(id: groupId) else { throw GroupError.notFound }
        try requireGroupAdmin(existing)
        try storage.messages.setGroupDescription(id: groupId, description: description)
        refreshConversations()
        if let stored = try storage.messages.group(id: groupId) {
            var update = Relay_Content_GroupUpdate()
            update.action = .describe
            update.description_p = description
            await sendGroupUpdateCustom(update, group: stored)
        }
        insertSystemLine("You updated the group description", inGroup: groupId)
    }

    func setGroupAvatar(_ data: Data, groupId: String) async throws {
        guard let existing = try storage.messages.group(id: groupId) else { throw GroupError.notFound }
        try requireGroupAdmin(existing)
        // Same encrypted-attachment path as media.
        let sealed = try AttachmentCipher.seal(data)
        let blobId = try await api.uploadAttachment(sealed.ciphertext)
        try storage.messages.setGroupAvatar(id: groupId, avatarData: data)
        refreshConversations()
        if let stored = try storage.messages.group(id: groupId) {
            var update = Relay_Content_GroupUpdate()
            update.action = .avatar
            var ptr = Relay_Content_AttachmentPointer()
            ptr.id = blobId
            ptr.key = sealed.key
            ptr.digest = sealed.digest
            ptr.contentType = "image/jpeg"
            update.avatar = ptr
            await sendGroupUpdateCustom(update, group: stored)
        }
    }

    /// The relay stores only ciphertext; the key is in the URL fragment. The
    /// embedded invite capability lets members verify a joiner held the link.
    func createGroupInviteLink(groupId: String) async throws -> String {
        guard let group = try storage.messages.group(id: groupId) else { throw GroupError.notFound }
        try requireGroupAdmin(group)
        // First link: create the invite capability and silently share it with members.
        if groupInviteKey(groupId) == nil {
            setGroupInviteKey(groupId, Self.randomInviteKey())
            var announce = Relay_Content_GroupUpdate()
            announce.action = .unspecified // silent; carries only the invite key
            await sendGroupUpdateCustom(announce, group: group)
        }
        guard let inviteKey = groupInviteKey(groupId) else { throw GroupError.notFound }
        let payload = GroupInvitePayload(
            groupId: groupId, name: group.name, members: group.members,
            distributionId: group.distributionId, inviteKey: inviteKey, admins: group.admins,
            revision: group.revision
        )
        let sealed = try AttachmentCipher.seal(try JSONEncoder().encode(payload))
        let (token, _) = try await api.createEncryptedGroupInvite(blob: sealed.ciphertext)
        let fragment = (sealed.key + sealed.digest).base64URLEncodedString()
        return "https://relaymsg.app/g/\(token)#\(fragment)"
    }

    /// Stops every invite link made so far from working: members only accept
    /// a self-join that carries the current capability, which this replaces.
    func resetGroupInviteLink(groupId: String) async throws {
        guard let existing = try storage.messages.group(id: groupId) else { throw GroupError.notFound }
        try requireGroupAdmin(existing)
        // A new revision, so members ahead of our last one don't drop it as stale.
        try storage.messages.upsertGroup(
            id: groupId, name: existing.name, distributionId: existing.distributionId,
            revision: existing.revision + 1, members: existing.members,
            admins: existing.admins, isAnnounceOnly: existing.isAnnounceOnly
        )
        guard let group = try storage.messages.group(id: groupId) else { throw GroupError.notFound }
        setGroupInviteKey(groupId, Self.randomInviteKey())
        var announce = Relay_Content_GroupUpdate()
        announce.action = .unspecified // silent; carries only the invite key
        await sendGroupUpdateCustom(announce, group: group)
        insertSystemLine("You reset the group's invite link", inGroup: groupId)
    }
}
