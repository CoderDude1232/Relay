//
//  AccountStorage.swift
//  Relay
//
//  Keeps the chat and group list (never message history) with the account, so
//  signing out and back in brings the chats back. The list is encrypted on the
//  phone with a key derived from the account password (Argon2id) and stored on
//  the relay as an opaque blob, padded so its size reveals little. The relay
//  can't read it; without the account password nobody can.
//

import Clibsodium
import CryptoKit
import Foundation
import RelayKit
import SecureStorage

enum AccountStorageCrypto {
    private static let magic = Data("RAS1".utf8)
    private static let padBlock = 4096

    /// Argon2id(password, salt = SHA-256("relay-account-storage-v1|" + account)[0..16]).
    /// Deliberately slow (~1 s); call off the main thread.
    nonisolated static func deriveKey(password: String, accountId: String) -> Data? {
        _ = sodium_init()
        let salt = Array(SHA256.hash(data: Data("relay-account-storage-v1|\(accountId)".utf8)).prefix(Int(crypto_pwhash_SALTBYTES)))
        var key = [UInt8](repeating: 0, count: 32)
        let rc = password.withCString { pw in
            crypto_pwhash(&key, UInt64(key.count), pw, UInt64(password.utf8.count), salt,
                          UInt64(crypto_pwhash_OPSLIMIT_MODERATE), Int(crypto_pwhash_MEMLIMIT_INTERACTIVE),
                          crypto_pwhash_ALG_ARGON2ID13)
        }
        return rc == 0 ? Data(key) : nil
    }

    /// "RAS1" | AES-GCM(len(UInt32 BE) | plaintext | zero padding to 4 KiB).
    nonisolated static func seal(_ plaintext: Data, key: Data) throws -> Data {
        var body = Data()
        withUnsafeBytes(of: UInt32(plaintext.count).bigEndian) { body.append(contentsOf: $0) }
        body.append(plaintext)
        let padded = ((body.count + padBlock - 1) / padBlock) * padBlock
        body.append(Data(count: padded - body.count))
        let box = try AES.GCM.seal(body, using: SymmetricKey(data: key), authenticating: magic)
        return magic + box.combined!
    }

    nonisolated static func open(_ blob: Data, key: Data) -> Data? {
        guard blob.prefix(4) == magic,
              let box = try? AES.GCM.SealedBox(combined: blob.dropFirst(4)),
              let body = try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: magic),
              body.count >= 4
        else { return nil }
        let length = Int(body.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard 4 + length <= body.count else { return nil }
        return body.subdata(in: 4..<(4 + length))
    }
}

extension MessagingService {
    private static let storageKeyKV = "me:accountStorageKey"
    private static let storageVersionKV = "me:accountStorageVersion"

    private var accountStorageKey: Data? {
        ((try? storage.database.query("SELECT value FROM kv WHERE key = ?", [.text(Self.storageKeyKV)])
            .first?.first?.data) ?? nil).flatMap { $0.count == 32 ? $0 : nil }
    }

    private var accountStorageVersion: Int64 {
        get {
            ((try? storage.database.query("SELECT value FROM kv WHERE key = ?", [.text(Self.storageVersionKV)])
                .first?.first?.data) ?? nil).flatMap { Int64(String(decoding: $0, as: UTF8.self)) } ?? 0
        }
        set {
            try? storage.database.run("INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
                                      [.text(Self.storageVersionKV), .blob(Data(String(newValue).utf8))])
        }
    }

    /// Re-bases on the server's version without reading the blob (used after a
    /// password change, when the old blob can't be decrypted any more).
    func accountStorageVersionReset(to version: Int64) { accountStorageVersion = version }

    /// Whether this device can keep the chat list with the account (it knows
    /// the key, i.e. the account password was entered or set here).
    var keepsChatListWithAccount: Bool { accountStorageKey != nil }

    /// Derives and remembers the storage key from the account password.
    func setAccountStorageKey(password: String) async {
        let account = credentials.accountId
        guard let key = await Task.detached(priority: .userInitiated, operation: {
            AccountStorageCrypto.deriveKey(password: password, accountId: account)
        }).value else { return }
        try? storage.database.run("INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
                                  [.text(Self.storageKeyKV), .blob(key)])
    }

    /// After sign-in: brings back the chat and group list (no messages). If the
    /// blob can't be opened (password changed via "forgot password"), it's
    /// just overwritten by the next upload.
    func restoreAccountStorage() async {
        guard let key = accountStorageKey, let stored = try? await apiClient.accountStorage() else { return }
        accountStorageVersion = stored.version
        guard let plaintext = AccountStorageCrypto.open(stored.blob, key: key),
              let snapshot = try? JSONDecoder().decode(BackupSnapshot.self, from: plaintext)
        else { return }
        importBackupSnapshot(snapshot)
    }

    /// The chat and group list, without messages.
    private func chatListSnapshot() -> BackupSnapshot {
        var convs: [BackupSnapshot.Conversation] = []
        var groups: [BackupSnapshot.Group] = []
        for conv in conversations where conv.peerAccount != noteToSelfAccount || conv.groupId != nil {
            convs.append(BackupSnapshot.Conversation(
                peerAccount: conv.peerAccount, username: conv.peerUsername,
                groupId: conv.groupId, messages: []
            ))
            if let gid = conv.groupId, let g = try? storage.messages.group(id: gid) {
                groups.append(BackupSnapshot.Group(
                    id: g.id, name: g.name, distributionId: g.distributionId, revision: g.revision,
                    members: g.members, admins: g.admins, isAnnounceOnly: g.isAnnounceOnly
                ))
            }
        }
        return BackupSnapshot(conversations: convs, groups: groups)
    }

    /// Fingerprint of the list, so uploads happen only when it really changed.
    var chatListFingerprint: String {
        conversations.map { "\($0.groupId ?? $0.peerAccount)" }.sorted().joined(separator: ",")
            + "|" + conversations.compactMap { $0.groupId }.compactMap { try? storage.messages.group(id: $0)?.revision }
                .map(String.init).joined(separator: ",")
    }

    /// Uploads (after a short pause, coalescing bursts) when the list changed.
    func scheduleAccountStorageUploadIfChanged() {
        guard keepsChatListWithAccount, !isDemoAccount else { return }
        let fingerprint = chatListFingerprint
        guard fingerprint != lastChatListFingerprint else { return }
        lastChatListFingerprint = fingerprint
        accountStorageUploadTask?.cancel()
        accountStorageUploadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            await self?.uploadAccountStorage()
        }
    }

    /// Encrypts and uploads the chat list. On a version conflict (another
    /// device wrote first) it merges in that device's list and retries once.
    func uploadAccountStorage() async {
        guard let key = accountStorageKey, !isDemoAccount else { return }
        for _ in 0..<2 {
            guard let json = try? JSONEncoder().encode(chatListSnapshot()),
                  let blob = try? AccountStorageCrypto.seal(json, key: key) else { return }
            do {
                accountStorageVersion = try await apiClient.putAccountStorage(blob, baseVersion: accountStorageVersion)
                return
            } catch RelayAPIError.http(status: 409, _) {
                await restoreAccountStorage() // merge the newer list, then retry
            } catch {
                return
            }
        }
    }
}
