//
//  AccountStorage.swift
//  Relay
//
//  Keeps the chat and group list (not message history) with the account as a
//  padded, opaque blob on the relay. The list is encrypted under a random
//  content key, and that key is stored in slots: one wrapped by an Argon2id key
//  from the account password, and one per passkey wrapped by a key from the
//  passkey's PRF output. Either can unlock the list on a new device.
//

import Clibsodium
import CryptoKit
import Foundation
import RelayKit
import SecureStorage

enum AccountStorageCrypto {
    private static let legacyMagic = Data("RAS1".utf8)
    private static let magic = Data("RAS2".utf8)
    private static let padBlock = 4096

    enum SlotKind: UInt8 {
        case password = 1
        case passkey = 2
        case recoveryKey = 3
    }

    /// A copy of the content key, wrapped for one way of unlocking.
    struct Slot: Equatable {
        let kind: SlotKind
        /// Empty for the password slot; the credential id for a passkey slot.
        let id: Data
        /// AES-GCM(content key), nonce | ciphertext | tag.
        let wrapped: Data
    }

    /// Salt for the passkey PRF, the same for every account.
    static let prfSalt = Data(SHA256.hash(data: Data("relay-account-storage-prf-v1".utf8)))

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

    /// Slot key for a passkey, from its PRF output.
    nonisolated static func passkeySlotKey(prfOutput: Data) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: prfOutput),
            info: Data("relay-account-storage-passkey-slot".utf8),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    nonisolated static func newContentKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    private static func slotAD(_ kind: SlotKind, _ id: Data) -> Data {
        Data("RAS2-slot".utf8) + [kind.rawValue] + id
    }

    nonisolated static func makeSlot(kind: SlotKind, id: Data = Data(), contentKey: Data, slotKey: Data) -> Slot? {
        guard let box = try? AES.GCM.seal(contentKey, using: SymmetricKey(data: slotKey), authenticating: slotAD(kind, id)),
              let combined = box.combined
        else { return nil }
        return Slot(kind: kind, id: id, wrapped: combined)
    }

    nonisolated static func unwrap(_ slot: Slot, slotKey: Data) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: slot.wrapped),
              let key = try? AES.GCM.open(box, using: SymmetricKey(data: slotKey), authenticating: slotAD(slot.kind, slot.id)),
              key.count == 32
        else { return nil }
        return key
    }

    /// slot count | per slot: kind | id length | id | wrapped length | wrapped.
    nonisolated static func encodeSlots(_ slots: [Slot]) -> Data {
        var out = Data([UInt8(slots.count)])
        for slot in slots {
            out.append(slot.kind.rawValue)
            out.append(UInt8(slot.id.count)); out.append(slot.id)
            out.append(UInt8(slot.wrapped.count)); out.append(slot.wrapped)
        }
        return out
    }

    /// Parses a slot table, returning the slots and the bytes it used.
    nonisolated static func decodeSlots(_ data: Data) -> (slots: [Slot], length: Int)? {
        let bytes = [UInt8](data)
        guard let count = bytes.first else { return nil }
        var i = 1
        var slots: [Slot] = []
        func take(_ n: Int) -> [UInt8]? {
            guard i + n <= bytes.count else { return nil }
            defer { i += n }
            return Array(bytes[i..<(i + n)])
        }
        for _ in 0..<count {
            guard let kindByte = take(1)?.first, let kind = SlotKind(rawValue: kindByte),
                  let idLen = take(1)?.first, let id = take(Int(idLen)),
                  let wrappedLen = take(1)?.first, let wrapped = take(Int(wrappedLen))
            else { return nil }
            slots.append(Slot(kind: kind, id: Data(id), wrapped: Data(wrapped)))
        }
        return (slots, i)
    }

    private static func pad(_ plaintext: Data) -> Data {
        var body = Data()
        withUnsafeBytes(of: UInt32(plaintext.count).bigEndian) { body.append(contentsOf: $0) }
        body.append(plaintext)
        let padded = ((body.count + padBlock - 1) / padBlock) * padBlock
        body.append(Data(count: padded - body.count))
        return body
    }

    private static func unpad(_ body: Data) -> Data? {
        guard body.count >= 4 else { return nil }
        let length = Int(body.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard 4 + length <= body.count else { return nil }
        return body.subdata(in: 4..<(4 + length))
    }

    /// "RAS2" | slots | AES-GCM(padded plaintext), with magic and slots as AD.
    nonisolated static func seal(_ plaintext: Data, contentKey: Data, slots: [Slot]) throws -> Data {
        let header = magic + encodeSlots(slots)
        let box = try AES.GCM.seal(pad(plaintext), using: SymmetricKey(data: contentKey), authenticating: header)
        return header + box.combined!
    }

    /// The slot table of a RAS2 blob.
    nonisolated static func slots(in blob: Data) -> [Slot]? {
        guard blob.prefix(4) == magic else { return nil }
        return decodeSlots(blob.dropFirst(4))?.slots
    }

    nonisolated static func isLegacy(_ blob: Data) -> Bool { blob.prefix(4) == legacyMagic }

    nonisolated static func open(_ blob: Data, contentKey: Data) -> Data? {
        guard blob.prefix(4) == magic, let (_, length) = decodeSlots(blob.dropFirst(4)) else { return nil }
        let header = blob.prefix(4 + length)
        guard let box = try? AES.GCM.SealedBox(combined: blob.dropFirst(4 + length)),
              let body = try? AES.GCM.open(box, using: SymmetricKey(data: contentKey), authenticating: header)
        else { return nil }
        return unpad(body)
    }

    /// "RAS1" | AES-GCM(padded plaintext) under the password key; read-only.
    nonisolated static func openLegacy(_ blob: Data, passwordKey: Data) -> Data? {
        guard blob.prefix(4) == legacyMagic,
              let box = try? AES.GCM.SealedBox(combined: blob.dropFirst(4)),
              let body = try? AES.GCM.open(box, using: SymmetricKey(data: passwordKey), authenticating: legacyMagic)
        else { return nil }
        return unpad(body)
    }
}

extension MessagingService {
    /// Argon2id key from the account password (wraps the password slot).
    private static let passwordKeyKV = "me:accountStorageKey"
    private static let contentKeyKV = "me:accountStorageContentKey"
    private static let slotsKV = "me:accountStorageSlots"
    private static let recoveryKeyKV = "me:recoveryKey"
    private static let storageVersionKV = "me:accountStorageVersion"

    private func kvData(_ key: String) -> Data? {
        (try? storage.database.query("SELECT value FROM kv WHERE key = ?", [.text(key)]).first?.first?.data) ?? nil
    }

    private func setKV(_ key: String, _ value: Data?) {
        if let value {
            try? storage.database.run("INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)", [.text(key), .blob(value)])
        } else {
            try? storage.database.run("DELETE FROM kv WHERE key = ?", [.text(key)])
        }
    }

    private var passwordKey: Data? { kvData(Self.passwordKeyKV).flatMap { $0.count == 32 ? $0 : nil } }
    private var contentKey: Data? { kvData(Self.contentKeyKV).flatMap { $0.count == 32 ? $0 : nil } }

    private var slots: [AccountStorageCrypto.Slot] {
        get { kvData(Self.slotsKV).flatMap { AccountStorageCrypto.decodeSlots($0)?.slots } ?? [] }
        set { setKV(Self.slotsKV, AccountStorageCrypto.encodeSlots(newValue)) }
    }

    private var accountStorageVersion: Int64 {
        get { kvData(Self.storageVersionKV).flatMap { Int64(String(decoding: $0, as: UTF8.self)) } ?? 0 }
        set { setKV(Self.storageVersionKV, Data(String(newValue).utf8)) }
    }

    /// Re-bases on the server's version without reading the blob.
    func accountStorageVersionReset(to version: Int64) { accountStorageVersion = version }

    /// Whether this device can keep the chat list with the account (it can
    /// unlock it with the account password or a passkey).
    var keepsChatListWithAccount: Bool { contentKey != nil || passwordKey != nil }

    /// Remembers the key from the account password. If the content key is known
    /// (password change), the password slot is rewrapped so passkeys keep working.
    func setAccountStorageKey(password: String) async {
        let account = credentials.accountId
        guard let key = await Task.detached(priority: .userInitiated, operation: {
            AccountStorageCrypto.deriveKey(password: password, accountId: account)
        }).value else { return }
        setKV(Self.passwordKeyKV, key)
        if let contentKey { replacePasswordSlot(contentKey: contentKey, passwordKey: key) }
    }

    private func replacePasswordSlot(contentKey: Data, passwordKey: Data) {
        guard let slot = AccountStorageCrypto.makeSlot(kind: .password, contentKey: contentKey, slotKey: passwordKey) else { return }
        slots = [slot] + slots.filter { $0.kind != .password }
    }

    /// The content key and slots to seal with, creating them on first use (or
    /// when converting a RAS1 list).
    private func ensureContentKey() -> Data {
        if let contentKey { return contentKey }
        let key = AccountStorageCrypto.newContentKey()
        setKV(Self.contentKeyKV, key)
        slots = []
        if let passwordKey { replacePasswordSlot(contentKey: key, passwordKey: passwordKey) }
        return key
    }

    /// Restores the chat and group list after sign-in, and picks up slots other
    /// devices added. A list this device can't open (password reset) is
    /// replaced by the next upload.
    func restoreAccountStorage() async {
        guard keepsChatListWithAccount, let stored = try? await apiClient.accountStorage() else { return }
        accountStorageVersion = stored.version
        guard let plaintext = openStored(stored.blob) else { return }
        importStored(plaintext)
    }

    /// The chat list, plus the recovery key kept alongside it. The list is
    /// merged in as always; the recovery key is taken only from a copy at
    /// least as new as one this device has seen, so a stale copy served by
    /// the relay can't bring back a key that was replaced.
    private func importStored(_ plaintext: Data) {
        let object = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any]
        let writtenAt = (object?[Self.writtenAtField] as? NSNumber)?.int64Value ?? 0
        let seen = storageSeenAt
        if writtenAt > seen { storageSeenAt = writtenAt }
        if writtenAt >= seen, let key = object?["recoveryKey"] as? String, !key.isEmpty {
            setKV(Self.recoveryKeyKV, Data(key.utf8))
        }
        if let snapshot = try? JSONDecoder().decode(BackupSnapshot.self, from: plaintext) {
            importBackupSnapshot(snapshot)
        }
    }

    /// The plaintext to upload and the write time inside it (the relay can't
    /// fake it). The time is recorded as seen only once the upload succeeds.
    private func storedPlaintext() -> (data: Data, writtenAt: Int64)? {
        guard let json = try? JSONEncoder().encode(chatListSnapshot()),
              var object = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        else { return nil }
        if let key = recoveryKey { object["recoveryKey"] = key }
        let writtenAt = max(Int64(Date().timeIntervalSince1970 * 1000), storageSeenAt + 1)
        object[Self.writtenAtField] = writtenAt
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return (data, writtenAt)
    }

    private var storageSeenAt: Int64 {
        get { kvData(Self.storageSeenAtKV).flatMap { Int64(String(decoding: $0, as: UTF8.self)) } ?? 0 }
        set { setKV(Self.storageSeenAtKV, Data(String(newValue).utf8)) }
    }

    private static let writtenAtField = "writtenAt"
    private static let storageSeenAtKV = "me:accountStorageSeenAt"

    private func openStored(_ blob: Data) -> Data? {
        if AccountStorageCrypto.isLegacy(blob) {
            return passwordKey.flatMap { AccountStorageCrypto.openLegacy(blob, passwordKey: $0) }
        }
        guard let serverSlots = AccountStorageCrypto.slots(in: blob) else { return nil }
        var key = contentKey
        if key == nil, let passwordKey, let slot = serverSlots.first(where: { $0.kind == .password }) {
            key = AccountStorageCrypto.unwrap(slot, slotKey: passwordKey)
        }
        guard let key, let plaintext = AccountStorageCrypto.open(blob, contentKey: key) else { return nil }
        setKV(Self.contentKeyKV, key)
        slots = serverSlots
        return plaintext
    }

    /// Unlocks the chat list with a passkey after a passkey sign-in.
    func restoreAccountStorage(passkeyCredentialId: Data, prfOutput: Data) async {
        await restoreAccountStorage(kind: .passkey, id: passkeyCredentialId,
                                    slotKey: AccountStorageCrypto.passkeySlotKey(prfOutput: prfOutput))
    }

    /// Unlocks the chat list with the recovery key after a recovery-key sign-in.
    func restoreAccountStorage(recoveryKey: String) async {
        setKV(Self.recoveryKeyKV, Data(RecoveryKey.format(recoveryKey).utf8))
        await restoreAccountStorage(kind: .recoveryKey, id: Data(), slotKey: RecoveryKey.slotKey(recoveryKey))
    }

    private func restoreAccountStorage(kind: AccountStorageCrypto.SlotKind, id: Data, slotKey: Data) async {
        guard let stored = try? await apiClient.accountStorage() else { return }
        accountStorageVersion = stored.version
        guard let serverSlots = AccountStorageCrypto.slots(in: stored.blob),
              let slot = serverSlots.first(where: { $0.kind == kind && $0.id == id }),
              let key = AccountStorageCrypto.unwrap(slot, slotKey: slotKey),
              let plaintext = AccountStorageCrypto.open(stored.blob, contentKey: key)
        else { return }
        setKV(Self.contentKeyKV, key)
        slots = serverSlots
        importStored(plaintext)
    }

    // MARK: Recovery key

    /// The account's recovery key, if this device knows it.
    var recoveryKey: String? {
        kvData(Self.recoveryKeyKV).map { String(decoding: $0, as: UTF8.self) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static let recoveryKeyHashV2KV = "relay.recoveryKey.hashV2"
    private static let accountPasswordUpdateNoticeKV = "relay.accountPassword.updateNotice"
    private static let noWayBackInNoticeKV = "relay.signIn.noWayBackInNotice"
    /// How often to repeat the warning while the account still has no way back in.
    private static let noWayBackInNoticeInterval: TimeInterval = 7 * 24 * 3600

    /// Re-registers a recovery key that this device knows under the hash
    /// sign-in now checks (older builds registered a hash of the raw key, which
    /// they sent at sign-in). Once per account.
    func upgradeRecoveryKeyHashIfNeeded() async {
        guard let key = recoveryKey, kvData(Self.recoveryKeyHashV2KV) == nil else { return }
        do {
            try await apiClient.setRecoveryKeyHash(RecoveryKey.hash(key))
            setKV(Self.recoveryKeyHashV2KV, Data([1]))
        } catch {
            // Try again next start.
        }
    }

    /// Tells the user, once, when their account password was stored by an
    /// older build: until they enter it again it can't be used to sign in on
    /// a new device. Settings keeps showing it until they do.
    func noteAccountPasswordNeedsUpdateIfNeeded() async {
        guard !isDemoAccount, kvData(Self.accountPasswordUpdateNoticeKV) == nil,
              let methods = try? await apiClient.signInMethods(), methods.accountPasswordNeedsUpdate
        else { return }
        setKV(Self.accountPasswordUpdateNoticeKV, Data([1]))
        postRelayNotice("Please enter your account password again in Settings → Account → Account Password. Relay now stores it differently, and until you do it can't be used to sign in on a new device.")
    }

    /// Warns when nothing could sign in to this account from a new device
    /// (no passkey, recovery key, usable account password or email): losing
    /// this iPhone would lose the account. Repeats weekly until fixed.
    func noteNoWayBackInIfNeeded() async {
        guard !isDemoAccount,
              let methods = try? await apiClient.signInMethods(), !methods.hasWayBackIn
        else { return }
        let now = Date().timeIntervalSince1970
        if let last = kvData(Self.noWayBackInNoticeKV).flatMap({ Double(String(decoding: $0, as: UTF8.self)) }),
           now - last < Self.noWayBackInNoticeInterval {
            return
        }
        setKV(Self.noWayBackInNoticeKV, Data(String(now).utf8))
        postRelayNotice("Your account has no way to sign in on a new device. If you lose this iPhone, you lose the account. Add a passkey or make a recovery key in Settings → Account → Sign-In.")
    }

    /// Makes a new recovery key (replacing any old one), registers its hash,
    /// and lets it unlock the chat list. The key is kept on this device and,
    /// encrypted, with the chat list so it can be viewed again elsewhere.
    @discardableResult
    func createRecoveryKey() async throws -> String {
        let key = RecoveryKey.generate()
        try await apiClient.setRecoveryKeyHash(RecoveryKey.hash(key))
        setKV(Self.recoveryKeyHashV2KV, Data([1]))
        await restoreAccountStorage()
        setKV(Self.recoveryKeyKV, Data(key.utf8))
        let content = ensureContentKey()
        if let slot = AccountStorageCrypto.makeSlot(kind: .recoveryKey, contentKey: content, slotKey: RecoveryKey.slotKey(key)) {
            slots = slots.filter { $0.kind != .recoveryKey } + [slot]
        }
        await uploadAccountStorage()
        return key
    }

    /// Lets a new passkey unlock the chat list, then uploads.
    func addPasskeySlot(credentialId: Data, prfOutput: Data) async {
        guard !isDemoAccount else { return }
        await restoreAccountStorage()
        let key = ensureContentKey()
        guard let slot = AccountStorageCrypto.makeSlot(
            kind: .passkey, id: credentialId, contentKey: key,
            slotKey: AccountStorageCrypto.passkeySlotKey(prfOutput: prfOutput)
        ) else { return }
        slots = slots.filter { !($0.kind == .passkey && $0.id == credentialId) } + [slot]
        await uploadAccountStorage()
    }

    func removePasskeySlot(credentialId: Data) async {
        guard contentKey != nil else { return }
        await restoreAccountStorage()
        slots = slots.filter { !($0.kind == .passkey && $0.id == credentialId) }
        await uploadAccountStorage()
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
    /// device wrote first) it merges in that device's list and slots, and
    /// retries once.
    func uploadAccountStorage() async {
        guard keepsChatListWithAccount, !isDemoAccount else { return }
        for _ in 0..<2 {
            let key = ensureContentKey()
            guard let stored = storedPlaintext(),
                  let blob = try? AccountStorageCrypto.seal(stored.data, contentKey: key, slots: slots) else { return }
            do {
                accountStorageVersion = try await apiClient.putAccountStorage(blob, baseVersion: accountStorageVersion)
                if stored.writtenAt > storageSeenAt { storageSeenAt = stored.writtenAt }
                return
            } catch RelayAPIError.http(status: 409, _) {
                await restoreAccountStorage()
            } catch {
                return
            }
        }
    }
}
