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
//  Left out: attachments, disappearing and view-once
//  messages, chats hidden by Panic Mode, message requests, live locations
//  and the local Relay notices chat.
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
    /// How often an unchanged-or-changed history is considered for upload.
    private static let historyUploadInterval: TimeInterval = 6 * 3600
    /// Data per segment, leaving room for the nonce and tag under the relay's 2 MiB cap.
    private static let historyChunkBytes = 1_900_000

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

    /// What goes into the backup: the local snapshot minus requests,
    /// empty (attachment-only) messages, live locations and the notices chat.
    private func historySnapshot() -> BackupSnapshot {
        var snapshot = exportBackupSnapshot()
        snapshot.conversations = snapshot.conversations.compactMap { conv in
            guard conv.accepted != false, conv.peerAccount != Self.relayOfficialAccount else { return nil }
            let messages = conv.messages.filter {
                !$0.body.isEmpty && !$0.body.hasPrefix(locationPrefix)
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

        let snapshot = historySnapshot()
        guard let json = try? JSONEncoder().encode(snapshot),
              let compressed = try? (json as NSData).compressed(using: .lzfse) as Data
        else { return }
        let digest = Data(SHA256.hash(data: compressed))
        if !force, historyKV(Self.historyDigestKV) == digest {
            setHistoryKV(Self.historyLastUploadKV, Data(String(now).utf8))
            return
        }
        let chunks = stride(from: 0, to: compressed.count, by: Self.historyChunkBytes).map {
            compressed.subdata(in: $0..<min($0 + Self.historyChunkBytes, compressed.count))
        }
        guard (1...999).contains(chunks.count) else { return }
        do {
            let existing = try await apiClient.historySegments()
            let generation = (existing.map { $0.seq / 1000 }.max() ?? 0) + 1
            for (index, chunk) in chunks.enumerated() {
                let part = "\(index + 1)/\(chunks.count)"
                let sealed = try AES.GCM.seal(chunk, using: key, authenticating: Self.historyAD(generation, part))
                guard let combined = sealed.combined else { return }
                try await apiClient.putHistorySegment(generation * 1000 + Int64(index + 1), combined)
            }
            let manifest = HistoryManifest(generation: generation, count: chunks.count, digest: digest,
                                           createdAt: Int64(now * 1000))
            let sealedManifest = try AES.GCM.seal(try JSONEncoder().encode(manifest), using: key,
                                                  authenticating: Self.historyAD(generation, "manifest"))
            guard let manifestData = sealedManifest.combined else { return }
            // The manifest goes last: a generation without one is incomplete.
            try await apiClient.putHistorySegment(generation * 1000, manifestData)
            for segment in existing where segment.seq / 1000 < generation {
                try? await apiClient.deleteHistorySegment(segment.seq)
            }
            setHistoryKV(Self.historyDigestKV, digest)
            setHistoryKV(Self.historyLastUploadKV, Data(String(now).utf8))
        } catch {
            historyLog.warning("history backup upload failed: \(PrivacyRedactor.error(error))")
        }
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
        let complete = Set(segments.filter { $0.seq % 1000 == 0 }.map { $0.seq / 1000 })
        guard let generation = complete.max() else {
            setHistoryKV(Self.historyRestoredKV, Data([1]))
            return
        }
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
            // The import marks chats read; chats that were already here keep
            // their own read state (and unread messages).
            let readState = ((try? storage.database.query("SELECT id, read_at FROM conversations")) ?? [])
                .compactMap { row -> (String, Int64)? in
                    guard let id = row.first?.string else { return nil }
                    return (id, row.count > 1 ? (row[1].int64 ?? 0) : 0)
                }
            importBackupSnapshot(snapshot)
            for (id, readAt) in readState {
                try? storage.database.run("UPDATE conversations SET read_at = ? WHERE id = ?", [.integer(readAt), .text(id)])
            }
            refreshConversations()
            setHistoryKV(Self.historyRestoredKV, Data([1]))
            postRelayNotice("Your message history was restored from your encrypted backup.")
        } catch is CryptoKitError {
            // Encrypted under a key this account no longer uses (say, the
            // password was reset and the old chat list couldn't be opened):
            // it can't be restored, so the next backup may replace it.
            setHistoryKV(Self.historyRestoredKV, Data([1]))
        } catch {
            historyLog.warning("history restore failed: \(PrivacyRedactor.error(error))")
        }
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
