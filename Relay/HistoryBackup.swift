//
//  HistoryBackup.swift
//  Relay
//
//  Keeps an encrypted copy of the user's message history (text only) with
//  their account on the relay, so signing in on a new phone brings chats back,
//  not just the chat list.
//
//  Each backup is a full snapshot, compressed, encrypted with a key derived
//  from the chat list's content key (which only the user's password, passkeys
//  and recovery key unlock), and split into numbered segments:
//  generation × 1000 + 1…n for the data, then generation × 1000 for a
//  manifest, uploaded last, that marks the generation complete. Older
//  generations are deleted once a newer one is complete.
//
//  Photos and files go in too while the account has Relay Supporter perks:
//  each attachment's cached ciphertext is uploaded once, sealed again under
//  the history key, as segments attachmentSeqBase + index × 1024 + 1…parts.
//  The snapshot carries each one's index and key; a restored attachment gets
//  the local id "hist-<index>-<parts>" and downloads from the backup when
//  it's opened. Attachments no snapshot refers to are deleted.
//
//  Left out: disappearing and view-once messages, chats hidden by Panic Mode,
//  message requests, live locations and the local Relay notices chat.
//

import CryptoKit
import Foundation
import OSLog
import RelayKit
import SecureStorage

private let historyLog = Logger(subsystem: "app.relaymsg", category: "history")

extension MessagingService {
    static let historyBackupEnabledKey = "relay.historyBackup"

    /// On by default for accounts that keep their chat list with the account.
    static var isHistoryBackupEnabled: Bool {
        UserDefaults.standard.object(forKey: historyBackupEnabledKey) as? Bool ?? true
    }

    private static let historyRestoredKV = "history:restoreDone"
    private static let historyLastUploadKV = "history:lastUploadAt"
    private static let historyDigestKV = "history:lastDigest"
    private static let historyLastSizeKV = "history:lastSize"
    private static let historyLastMessagesKV = "history:lastMessages"
    /// How often an unchanged-or-changed history is considered for upload.
    private static let historyUploadInterval: TimeInterval = 6 * 3600
    /// Data per segment, leaving room for the nonce and tag under the relay's 2 MiB cap.
    private static let historyChunkBytes = 1_900_000
    /// Attachment segments start here, far above any snapshot generation's.
    static let historyAttachmentSeqBase: Int64 = 1 << 50
    private static let historyAttachmentMaxParts = 1023
    private static let historyAttachmentKVPrefix = "history:att:"

    static func historyAttachmentId(index: Int64, parts: Int) -> String { "hist-\(index)-\(parts)" }

    static func parseHistoryAttachmentId(_ id: String) -> (index: Int64, parts: Int)? {
        let fields = id.split(separator: "-")
        guard fields.count == 3, fields[0] == "hist", let index = Int64(fields[1]), let parts = Int(fields[2]),
              index >= 0, (1...historyAttachmentMaxParts).contains(parts) else { return nil }
        return (index, parts)
    }

    private static func historyAttachmentSeq(_ index: Int64, part: Int) -> Int64 {
        historyAttachmentSeqBase + index * 1024 + Int64(part)
    }

    private static func historyAttachmentAD(_ index: Int64, _ part: Int, _ parts: Int) -> Data {
        Data("relay-history-att-v1|\(index)|\(part)/\(parts)".utf8)
    }

    private static func isSnapshotSegment(_ seq: Int64) -> Bool { seq < historyAttachmentSeqBase }

    private struct HistoryManifest: Codable {
        let generation: Int64
        let count: Int
        /// SHA-256 of the compressed snapshot, checked after reassembly.
        let digest: Data
        let createdAt: Int64
    }

    private func historyKV(_ key: String) -> Data? {
        (try? storage.database.query("SELECT value FROM kv WHERE key = ?", [.text(key)]).first?.first?.data) ?? nil
    }

    private func setHistoryKV(_ key: String, _ value: Data) {
        try? storage.database.run("INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)", [.text(key), .blob(value)])
    }

    private static func historyAD(_ generation: Int64, _ part: String) -> Data {
        Data("relay-history-v1|\(generation)|\(part)".utf8)
    }

    /// What goes into the backup: the local snapshot minus requests, live
    /// locations and the notices chat, with each message's backed-up
    /// attachments (messages with neither text nor those are left out).
    /// `keepingEmpty` keeps messages without text (to list whose
    /// attachments may be backed up).
    private func historySnapshot(
        attachments: [String: [BackupSnapshot.Attachment]] = [:], keepingEmpty: Bool = false
    ) -> BackupSnapshot {
        var snapshot = exportBackupSnapshot()
        snapshot.conversations = snapshot.conversations.compactMap { conv in
            guard conv.accepted != false, conv.peerAccount != Self.relayOfficialAccount else { return nil }
            let messages: [BackupSnapshot.Message] = conv.messages.compactMap { message in
                guard !message.body.hasPrefix(locationPrefix) else { return nil }
                var m = message
                m.attachments = attachments[m.id]
                return m.body.isEmpty && m.attachments == nil && !keepingEmpty ? nil : m
            }
            guard !messages.isEmpty || conv.groupId != nil else { return nil }
            var kept = BackupSnapshot.Conversation(
                peerAccount: conv.peerAccount, username: conv.username, groupId: conv.groupId, messages: messages)
            kept.accepted = conv.accepted
            kept.disappearingSeconds = conv.disappearingSeconds
            kept.mediaRequiresBiometric = conv.mediaRequiresBiometric
            kept.requireBiometricChat = conv.requireBiometricChat
            kept.hidePreviews = conv.hidePreviews
            return kept
        }
        let keptGroups = Set(snapshot.conversations.compactMap(\.groupId))
        snapshot.groups = snapshot.groups.filter { keptGroups.contains($0.id) }
        return snapshot
    }

    /// When the backup was last confirmed up to date, if ever.
    var lastHistoryBackupDate: Date? {
        _ = historyBackupRevision
        return historyKV(Self.historyLastUploadKV)
            .flatMap { Double(String(decoding: $0, as: UTF8.self)) }
            .map { Date(timeIntervalSince1970: $0) }
    }

    /// Encrypted size and message count of the last backup made here.
    var lastHistoryBackupSummary: (bytes: Int, messages: Int)? {
        _ = historyBackupRevision
        guard let bytes = historyKV(Self.historyLastSizeKV).flatMap({ Int(String(decoding: $0, as: UTF8.self)) }) else { return nil }
        let messages = historyKV(Self.historyLastMessagesKV).flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        return (bytes, messages)
    }

    /// Whether this device can back up at all (and has finished its restore).
    var canBackUpHistory: Bool {
        Self.isHistoryBackupEnabled && !isDemoAccount && keepsChatListWithAccount && historyBackupKey != nil
    }

    // MARK: Upload

    /// Uploads a new snapshot if history backup is on, the last one is more
    /// than a few hours old and something changed. Never before this device
    /// has tried to restore what's already there: a fresh sign-in would
    /// otherwise replace the account's history with an empty one.
    func backUpHistoryIfDue(force: Bool = false) async {
        guard Self.isHistoryBackupEnabled, !isDemoAccount, keepsChatListWithAccount,
              let key = historyBackupKey, historyKV(Self.historyRestoredKV) != nil
        else { return }
        let now = Date().timeIntervalSince1970
        let last = historyKV(Self.historyLastUploadKV).flatMap { Double(String(decoding: $0, as: UTF8.self)) } ?? 0
        guard force || now - last >= Self.historyUploadInterval else { return }

        guard historyBackupProgress == nil else { return } // one at a time
        let existing: [RelayAPIClient.HistorySegment]
        do {
            existing = try await apiClient.historySegments()
        } catch {
            historyBackupError = Self.backupErrorMessage(error)
            return
        }
        let withAttachments = Supporter.shared.hasAccountPerks
        var attachments: [String: [BackupSnapshot.Attachment]] = [:]
        if withAttachments {
            let eligible = Set(historySnapshot(keepingEmpty: true).conversations.flatMap { $0.messages.map(\.id) })
            attachments = await backUpAttachments(existing: existing, eligible: eligible, key: key)
        }
        let snapshot = historySnapshot(attachments: attachments)
        guard let json = try? JSONEncoder().encode(snapshot),
              let compressed = try? (json as NSData).compressed(using: .lzfse) as Data
        else { return }
        let digest = Data(SHA256.hash(data: compressed))
        if !force, historyKV(Self.historyDigestKV) == digest {
            setHistoryKV(Self.historyLastUploadKV, Data(String(now).utf8))
            if !withAttachments { await deleteUnusedAttachmentSegments(existing, keeping: []) }
            return
        }
        let chunks = stride(from: 0, to: compressed.count, by: Self.historyChunkBytes).map {
            compressed.subdata(in: $0..<min($0 + Self.historyChunkBytes, compressed.count))
        }
        guard (1...999).contains(chunks.count) else { return }
        historyBackupProgress = 0
        defer {
            historyBackupProgress = nil
            historyBackupRevision += 1
        }
        let steps = Double(chunks.count + 1)
        do {
            // Seconds since 1970, so two devices backing up at once don't
            // write into the same generation; the newest complete one wins.
            let generation = max((existing.filter { Self.isSnapshotSegment($0.seq) }.map { $0.seq / 1000 }.max() ?? 0) + 1,
                                 Int64(now))
            for (index, chunk) in chunks.enumerated() {
                let part = "\(index + 1)/\(chunks.count)"
                let sealed = try AES.GCM.seal(chunk, using: key, authenticating: Self.historyAD(generation, part))
                guard let combined = sealed.combined else { return }
                try await apiClient.putHistorySegment(generation * 1000 + Int64(index + 1), combined)
                historyBackupProgress = Double(index + 1) / steps
            }
            let manifest = HistoryManifest(generation: generation, count: chunks.count, digest: digest,
                                           createdAt: Int64(now * 1000))
            let sealedManifest = try AES.GCM.seal(try JSONEncoder().encode(manifest), using: key,
                                                  authenticating: Self.historyAD(generation, "manifest"))
            guard let manifestData = sealedManifest.combined else { return }
            // The manifest goes last: a generation without one is incomplete.
            try await apiClient.putHistorySegment(generation * 1000, manifestData)
            for segment in existing where Self.isSnapshotSegment(segment.seq) && segment.seq / 1000 < generation {
                try? await apiClient.deleteHistorySegment(segment.seq)
            }
            let referenced = Set(attachments.values.flatMap { $0.map(\.index) })
            await deleteUnusedAttachmentSegments(existing, keeping: referenced)
            setHistoryKV(Self.historyDigestKV, digest)
            setHistoryKV(Self.historyLastUploadKV, Data(String(now).utf8))
            setHistoryKV(Self.historyLastSizeKV, Data(String(compressed.count).utf8))
            let messageCount = snapshot.conversations.reduce(0) { $0 + $1.messages.count }
            setHistoryKV(Self.historyLastMessagesKV, Data(String(messageCount).utf8))
            historyBackupError = nil
        } catch {
            historyLog.warning("history backup upload failed: \(PrivacyRedactor.error(error))")
            historyBackupError = Self.backupErrorMessage(error)
        }
    }

    private static func backupErrorMessage(_ error: Error) -> String {
        if let api = error as? RelayAPIError, case .rateLimited = api {
            return "Too many backups in a short time. It'll try again later."
        }
        if let api = error as? RelayAPIError, case .http(let status, _) = api {
            switch status {
            case 507: return "Your backup is over the storage limit. Older messages may need to be deleted."
            case 429: return "Too many backups in a short time. It'll try again later."
            default: break
            }
        }
        if (error as? URLError) != nil {
            return "Couldn't reach Relay. It'll try again when you're back online."
        }
        return "The last backup didn't finish. It'll try again later."
    }

    // MARK: Restore

    /// Brings back the newest complete backup, once per sign-in. Messages
    /// already here are skipped. Until this has run (or found nothing to
    /// restore), no backup is uploaded from this device.
    func restoreHistoryIfNeeded() async {
        guard historyKV(Self.historyRestoredKV) == nil, !isDemoAccount, keepsChatListWithAccount,
              let key = historyBackupKey
        else { return }
        let segments: [RelayAPIClient.HistorySegment]
        do {
            segments = try await apiClient.historySegments()
        } catch {
            return // try again next connection
        }
        let complete = Set(segments.filter { Self.isSnapshotSegment($0.seq) && $0.seq % 1000 == 0 }.map { $0.seq / 1000 })
        guard let generation = complete.max() else {
            setHistoryKV(Self.historyRestoredKV, Data([1]))
            return
        }
        isRestoringHistory = true
        defer { isRestoringHistory = false }
        do {
            let manifestBox = try AES.GCM.SealedBox(combined: try await apiClient.historySegment(generation * 1000))
            let manifest = try JSONDecoder().decode(
                HistoryManifest.self,
                from: try AES.GCM.open(manifestBox, using: key, authenticating: Self.historyAD(generation, "manifest")))
            guard manifest.generation == generation, (1...999).contains(manifest.count) else { throw RelayAPIError.malformedResponse }
            var compressed = Data()
            for index in 1...manifest.count {
                let box = try AES.GCM.SealedBox(combined: try await apiClient.historySegment(generation * 1000 + Int64(index)))
                compressed.append(try AES.GCM.open(box, using: key,
                                                   authenticating: Self.historyAD(generation, "\(index)/\(manifest.count)")))
            }
            guard Data(SHA256.hash(data: compressed)) == manifest.digest,
                  let json = try? (compressed as NSData).decompressed(using: .lzfse) as Data
            else { throw RelayAPIError.malformedResponse }
            let snapshot = try JSONDecoder().decode(BackupSnapshot.self, from: json)
            // Restored messages were seen on the old phone: each chat's read
            // marker covers at least its newest restored message. Messages that
            // arrived here after the backup was made stay unread.
            let readState = ((try? storage.database.query("SELECT id, read_at FROM conversations")) ?? [])
                .compactMap { row -> (String, Int64)? in
                    guard let id = row.first?.string else { return nil }
                    return (id, row.count > 1 ? (row[1].int64 ?? 0) : 0)
                }
            importBackupSnapshot(snapshot)
            var restoredUpTo: [String: Int64] = [:]
            for conv in snapshot.conversations {
                guard let newest = conv.messages.map(\.timestamp).max() else { continue }
                let id: String? = if let gid = conv.groupId {
                    (try? storage.messages.groupConversationId(groupId: gid)) ?? nil
                } else {
                    (try? storage.database.query(
                        "SELECT id FROM conversations WHERE peer_account = ? AND group_id IS NULL",
                        [.text(conv.peerAccount)]).first?.first?.string) ?? nil
                }
                if let id { restoredUpTo[id] = max(restoredUpTo[id] ?? 0, newest) }
            }
            for (id, readAt) in readState {
                let marker = max(readAt, restoredUpTo[id] ?? 0)
                try? storage.database.run("UPDATE conversations SET read_at = ? WHERE id = ?", [.integer(marker), .text(id)])
                // Read on the old phone, so opening the chat sends no read
                // receipts for them.
                if let upTo = restoredUpTo[id] {
                    try? storage.database.run(
                        "UPDATE messages SET status = 'read' WHERE conversation_id = ? AND is_outgoing = 0 AND status = 'received' AND timestamp <= ?",
                        [.text(id), .integer(upTo)])
                }
            }
            refreshConversations()
            setHistoryKV(Self.historyRestoredKV, Data([1]))
            let messageCount = snapshot.conversations.reduce(0) { $0 + $1.messages.count }
            let chatCount = snapshot.conversations.filter { !$0.messages.isEmpty }.count
            let hasAttachments = snapshot.conversations.contains { $0.messages.contains { $0.attachments?.isEmpty == false } }
            let when = Date(timeIntervalSince1970: Double(manifest.createdAt) / 1000)
                .formatted(date: .abbreviated, time: .shortened)
            postRelayNotice(messageCount == 0
                ? "Your encrypted backup from \(when) had no messages to restore."
                : "Restored \(messageCount) \(messageCount == 1 ? "message" : "messages") in \(chatCount) \(chatCount == 1 ? "chat" : "chats") from your encrypted backup of \(when). \(hasAttachments ? "Photos and files download as you open them." : "Photos and files aren't part of the backup.")")
        } catch is CryptoKitError {
            // Encrypted under a key this account no longer uses (say, the
            // password was reset and the old chat list couldn't be opened):
            // it can't be restored, so the next backup may replace it.
            setHistoryKV(Self.historyRestoredKV, Data([1]))
            postRelayNotice("Your earlier message backup couldn't be opened: it was locked with sign-in details that have since changed. New messages will be backed up from now on.")
        } catch {
            historyLog.warning("history restore failed: \(PrivacyRedactor.error(error))")
        }
    }

    // MARK: Attachments (Relay Supporter)

    /// Uploads attachments not yet in the backup and returns every backed-up
    /// one by message id. Stops adding new ones when the quota is full.
    private func backUpAttachments(
        existing: [RelayAPIClient.HistorySegment], eligible: Set<String>, key: SymmetricKey
    ) async -> [String: [BackupSnapshot.Attachment]] {
        let present = Set(existing.map(\.seq))
        var nextIndex = (existing.filter { !Self.isSnapshotSegment($0.seq) }
            .map { ($0.seq - Self.historyAttachmentSeqBase) / 1024 }.max() ?? -1) + 1
        let rows = (try? storage.database.query(
            """
            SELECT a.id, a.message_id, a.key, a.digest, a.content_type, a.size, a.filename, a.width, a.height
            FROM attachments a JOIN messages m ON a.message_id = m.id
            ORDER BY m.timestamp, a.ordinal
            """)) ?? []
        var out: [String: [BackupSnapshot.Attachment]] = [:]
        var full = false
        for row in rows {
            guard row.count >= 9, let id = row[0].string, let messageId = row[1].string,
                  let attKey = row[2].data, let digest = row[3].data, let contentType = row[4].string,
                  eligible.contains(messageId)
            else { continue }
            // Already there: restored from the backup, or uploaded before
            // (and its first segment is still on the relay).
            var placed = Self.parseHistoryAttachmentId(id)
            if placed == nil, let saved = historyKV(Self.historyAttachmentKVPrefix + id),
               let parsed = Self.parseHistoryAttachmentId(String(decoding: saved, as: UTF8.self)) {
                placed = parsed
            }
            if let p = placed, !present.contains(Self.historyAttachmentSeq(p.index, part: 1)) { placed = nil }
            if placed == nil, !full, let data = try? attachmentStore.read(id) {
                do {
                    placed = try await uploadHistoryAttachment(data, index: nextIndex, key: key)
                    nextIndex += 1
                    if let p = placed {
                        setHistoryKV(Self.historyAttachmentKVPrefix + id,
                                     Data(Self.historyAttachmentId(index: p.index, parts: p.parts).utf8))
                    }
                } catch {
                    full = true // over quota or offline: the text still goes up
                    historyLog.warning("attachment backup stopped: \(PrivacyRedactor.error(error))")
                }
            }
            guard let p = placed else { continue }
            out[messageId, default: []].append(BackupSnapshot.Attachment(
                index: p.index, parts: p.parts, key: attKey, digest: digest, contentType: contentType,
                size: row[5].int64 ?? 0, filename: row[6].string,
                width: Int(row[7].int64 ?? 0), height: Int(row[8].int64 ?? 0)))
        }
        return out
    }

    private func uploadHistoryAttachment(_ data: Data, index: Int64, key: SymmetricKey) async throws -> (index: Int64, parts: Int)? {
        let parts = (data.count + Self.historyChunkBytes - 1) / Self.historyChunkBytes
        guard (1...Self.historyAttachmentMaxParts).contains(parts) else { return nil }
        for part in 1...parts {
            let start = (part - 1) * Self.historyChunkBytes
            let chunk = data.subdata(in: start..<min(start + Self.historyChunkBytes, data.count))
            let sealed = try AES.GCM.seal(chunk, using: key, authenticating: Self.historyAttachmentAD(index, part, parts))
            guard let combined = sealed.combined else { return nil }
            try await apiClient.putHistorySegment(Self.historyAttachmentSeq(index, part: part), combined)
        }
        return (index, parts)
    }

    /// Deletes attachment segments no snapshot refers to.
    private func deleteUnusedAttachmentSegments(_ existing: [RelayAPIClient.HistorySegment], keeping: Set<Int64>) async {
        for segment in existing where !Self.isSnapshotSegment(segment.seq) {
            let index = (segment.seq - Self.historyAttachmentSeqBase) / 1024
            if !keeping.contains(index) { try? await apiClient.deleteHistorySegment(segment.seq) }
        }
        if keeping.isEmpty {
            try? storage.database.run("DELETE FROM kv WHERE key LIKE ?", [.text(Self.historyAttachmentKVPrefix + "%")])
        }
    }

    /// A backed-up attachment's ciphertext, as it was cached on the old device.
    func historyAttachment(index: Int64, parts: Int, digest: Data) async throws -> Data {
        guard let key = historyBackupKey else { throw RelayAPIError.malformedResponse }
        var data = Data()
        for part in 1...parts {
            let box = try AES.GCM.SealedBox(combined: try await apiClient.historySegment(Self.historyAttachmentSeq(index, part: part)))
            data.append(try AES.GCM.open(box, using: key, authenticating: Self.historyAttachmentAD(index, part, parts)))
        }
        guard Data(SHA256.hash(data: data)) == digest else { throw RelayAPIError.malformedResponse }
        return data
    }

    /// Turning the backup off deletes what the relay holds.
    func setHistoryBackupEnabled(_ enabled: Bool) async {
        UserDefaults.standard.set(enabled, forKey: Self.historyBackupEnabledKey)
        if enabled {
            await backUpHistoryIfDue(force: true)
        } else {
            try? await apiClient.deleteAllHistory()
            try? storage.database.run("DELETE FROM kv WHERE key IN (?, ?)",
                                      [.text(Self.historyDigestKV), .text(Self.historyLastUploadKV)])
        }
    }
}
