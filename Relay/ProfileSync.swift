//
//  ProfileSync.swift
//  Relay
//
//  Profiles contacts fetch for themselves (content.proto EncryptedProfile,
//  server README "Encrypted profiles"). Our name, photo, bio and links are
//  kept on the relay as one fixed-size blob, encrypted under a profile key
//  only our contacts hold (it travels in our ProfileUpdate), at an id derived
//  from that key, so the relay can't tell whose profile it is. Contacts fetch
//  it whenever they like: after connecting, when a chat opens and straight
//  after a restore, so a photo is never stuck at whatever was last pushed.
//
//  The profile key goes with the chat list (AccountStorage.swift), so all our
//  devices share it and a restored device keeps contacts' keys. Blocking
//  someone changes it, and everyone else is sent the new one.
//

import CryptoKit
import Foundation
import OSLog
import RelayKit
import SecureStorage
import SwiftProtobuf
import UIKit

private let profileLog = Logger(subsystem: "app.relaymsg", category: "profiles")

extension MessagingService {
    static let myProfileKeyKV = "me:profileKey"
    /// When the key was made or adopted (ms), so the newest wins across devices.
    static let myProfileKeyAtKV = "me:profileKeyAt"
    private static let myProfileUploadedKV = "me:profileUploaded"   // "<rev>|<key tag>"
    private static let myProfileUploadedAtKV = "me:profileUploadedAt"
    private static let profileSyncAtKV = "me:profileSyncAt"
    static let blobSize = 64 << 10

    struct ProfileKeys {
        let id: Data
        let write: Data
        let enc: SymmetricKey

        init(_ key: Data) {
            func derive(_ label: String) -> SymmetricKey {
                HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key), info: Data(label.utf8), outputByteCount: 32)
            }
            id = derive("relay-profile-v1-id").withUnsafeBytes { Data($0) }
            write = derive("relay-profile-v1-write").withUnsafeBytes { Data($0) }
            enc = derive("relay-profile-v1-enc")
        }
    }

    // MARK: - Keys

    private func profileKV(_ key: String) -> Data? {
        (try? storage.database.query("SELECT value FROM kv WHERE key = ?", [.text(key)]).first?.first?.data) ?? nil
    }

    private func setProfileKV(_ key: String, _ value: Data?) {
        if let value {
            try? storage.database.run("INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)", [.text(key), .blob(value)])
        } else {
            try? storage.database.run("DELETE FROM kv WHERE key = ?", [.text(key)])
        }
    }

    /// Our profile key, made on first use.
    var myProfileKey: Data {
        if let key = profileKV(Self.myProfileKeyKV), key.count == 32 { return key }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        setProfileKV(Self.myProfileKeyKV, key)
        writeKVInt(Self.myProfileKeyAtKV, Int64(Date().timeIntervalSince1970 * 1000))
        return key
    }

    /// Takes the profile key another of our devices uses, if it's newer than
    /// ours (from the chat list).
    func adoptMyProfileKey(_ key: Data, madeAt: Int64) {
        guard key.count == 32, key != profileKV(Self.myProfileKeyKV), madeAt > readKVInt(Self.myProfileKeyAtKV) else { return }
        setProfileKV(Self.myProfileKeyKV, key)
        writeKVInt(Self.myProfileKeyAtKV, madeAt)
        distributeProfileUpdate()
        Task { await uploadMyProfile() }
    }

    static func peerProfileKeyKV(_ account: String) -> String { "ppk:\(account)" }
    private static func peerProfileETagKV(_ account: String) -> String { "ppe:\(account)" }
    private static func peerProfileFetchedKV(_ account: String) -> String { "ppf:\(account)" }

    func peerProfileKey(_ account: String) -> Data? {
        profileKV(Self.peerProfileKeyKV(account)).flatMap { $0.count == 32 ? $0 : nil }
    }

    /// Keeps a contact's profile key; a new one is fetched with straight away.
    func rememberPeerProfileKey(_ key: Data, for account: String) {
        guard key.count == 32, key != peerProfileKey(account) else { return }
        setProfileKV(Self.peerProfileKeyKV(account), key)
        setProfileKV(Self.peerProfileETagKV(account), nil)
        scheduleAccountStorageUploadIfChanged()
        Task { await refreshPeerProfile(account, maxAge: 0) }
    }

    /// Every contact's profile key, for the chat list.
    func peerProfileKeys() -> [String: Data] {
        let rows = (try? storage.database.query("SELECT key, value FROM kv WHERE key LIKE 'ppk:%'")) ?? []
        var keys: [String: Data] = [:]
        for row in rows {
            guard let name = row.first?.string, let value = row.count > 1 ? row[1].data : nil, value.count == 32 else { continue }
            keys[String(name.dropFirst(4))] = value
        }
        return keys
    }

    // MARK: - Our profile

    /// Uploads our profile when it or the key changed, and weekly regardless so
    /// the relay keeps it.
    func uploadMyProfile(force: Bool = false) async {
        guard !isDemoAccount else { return }
        let key = myProfileKey
        let marker = Data("\(max(myProfileRevision, 1))|\(Self.keyTag(key))".utf8)
        let age = Int64(Date().timeIntervalSince1970) - readKVInt(Self.myProfileUploadedAtKV)
        guard force || profileKV(Self.myProfileUploadedKV) != marker || age > 7 * 86400 else { return }
        var profile = Relay_Content_EncryptedProfile()
        profile.displayName = myDisplayName ?? ""
        profile.timestamp = max(myProfileRevision, 1)
        profile.status = myStatus
        profile.bio = myBio
        profile.links = myLinks.map {
            var l = Relay_Content_ProfileLink()
            l.label = $0.label
            l.url = $0.url
            return l
        }
        let keys = ProfileKeys(key)
        do {
            let blob = try Self.sealProfile(profile, avatar: myAvatarData, keys: keys)
            try await apiClient.putProfile(id: keys.id, writeSecret: keys.write, blob: blob)
            setProfileKV(Self.myProfileUploadedKV, marker)
            writeKVInt(Self.myProfileUploadedAtKV, Int64(Date().timeIntervalSince1970))
        } catch {
            profileLog.error("profile upload failed: \(PrivacyRedactor.error(error), privacy: .public)")
        }
    }

    /// After blocking someone: a new key, the old profile deleted, and the new
    /// key sent to everyone else (distributeProfileUpdate skips the blocked).
    func rotateMyProfileKey() async {
        let old = ProfileKeys(myProfileKey)
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        setProfileKV(Self.myProfileKeyKV, key)
        writeKVInt(Self.myProfileKeyAtKV, Int64(Date().timeIntervalSince1970 * 1000))
        scheduleAccountStorageUploadIfChanged()
        await uploadMyProfile(force: true)
        try? await apiClient.deleteProfile(id: old.id, writeSecret: old.write)
        distributeProfileUpdate()
    }

    // MARK: - Contacts' profiles

    /// Fetches a contact's profile unless it was checked within `maxAge`
    /// seconds. Unchanged profiles aren't downloaded again.
    func refreshPeerProfile(_ account: String, maxAge: TimeInterval) async {
        guard let key = peerProfileKey(account), !isBlocked(account) else { return }
        let now = Int64(Date().timeIntervalSince1970)
        guard now - readKVInt(Self.peerProfileFetchedKV(account)) >= Int64(maxAge) else { return }
        writeKVInt(Self.peerProfileFetchedKV(account), now)
        let keys = ProfileKeys(key)
        let etag = profileKV(Self.peerProfileETagKV(account)).flatMap { String(data: $0, encoding: .utf8) }
        do {
            switch try await apiClient.fetchProfile(id: keys.id, etag: etag) {
            case .unchanged, .missing:
                return
            case .changed(let blob, let newETag):
                guard let profile = Self.openProfile(blob, keys: keys) else {
                    profileLog.error("a contact's profile didn't decrypt")
                    return
                }
                await applyFetchedProfile(profile, account: account)
                profileLog.info("fetched a contact's profile (photo: \(!profile.avatarJpeg.isEmpty, privacy: .public))")
                setProfileKV(Self.peerProfileETagKV(account), newETag.map { Data($0.utf8) })
            }
        } catch {
            // Tried again next time.
            writeKVInt(Self.peerProfileFetchedKV(account), 0)
        }
    }

    /// Every contact whose key we have, a few at a time.
    func refreshPeerProfiles(maxAge: TimeInterval) async {
        let accounts = Array(peerProfileKeys().keys)
        await withTaskGroup(of: Void.self) { group in
            var next = accounts.makeIterator()
            for _ in 0..<4 {
                guard let account = next.next() else { break }
                group.addTask { await self.refreshPeerProfile(account, maxAge: maxAge) }
            }
            while await group.next() != nil {
                if let account = next.next() {
                    group.addTask { await self.refreshPeerProfile(account, maxAge: maxAge) }
                }
            }
        }
    }

    /// On connecting: our profile up to date on the relay, and contacts'
    /// checked at most every 6 hours.
    func syncProfilesAfterConnecting() async {
        let now = Int64(Date().timeIntervalSince1970)
        guard now - readKVInt(Self.profileSyncAtKV) >= 15 * 60 else { return }
        writeKVInt(Self.profileSyncAtKV, now)
        await uploadMyProfile()
        // Contacts who don't have our current key yet (first run of this
        // build, or a key changed elsewhere) get it now, once.
        distributeProfileUpdate()
        await refreshPeerProfiles(maxAge: 6 * 3600)
    }

    // MARK: - Encryption

    static func keyTag(_ key: Data) -> Int64 {
        Int64(bitPattern: SHA256.hash(data: key).prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
    }

    /// Largest serialized profile: the blob less nonce, tag and length.
    private static let maxProfileBytes = blobSize - 12 - 16 - 4

    /// Pads and encrypts `profile` with our photo, re-encoding the photo
    /// smaller until it fits.
    static func sealProfile(_ profile: Relay_Content_EncryptedProfile, avatar: Data?, keys: ProfileKeys) throws -> Data {
        var profile = profile
        var body = try profile.serializedData()
        if let avatar {
            for size in [512, 384, 256, 192, 128] {
                profile.avatarJpeg = size == 512 ? avatar : (SafeImage.avatarJPEG(from: avatar, maxPixelSize: size) ?? Data())
                body = try profile.serializedData()
                if body.count <= maxProfileBytes { break }
            }
        }
        if body.count > maxProfileBytes {
            profile.avatarJpeg = Data()
            body = try profile.serializedData()
        }
        guard body.count <= maxProfileBytes else { throw RelayAPIError.malformedResponse }
        var plaintext = Data()
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { plaintext.append(contentsOf: $0) }
        plaintext.append(body)
        plaintext.append(Data(count: blobSize - 12 - 16 - plaintext.count))
        guard let sealed = try AES.GCM.seal(plaintext, using: keys.enc, authenticating: keys.id).combined else {
            throw RelayAPIError.malformedResponse
        }
        return sealed
    }

    static func openProfile(_ blob: Data, keys: ProfileKeys) -> Relay_Content_EncryptedProfile? {
        guard blob.count == blobSize,
              let box = try? AES.GCM.SealedBox(combined: blob),
              let plaintext = try? AES.GCM.open(box, using: keys.enc, authenticating: keys.id),
              plaintext.count >= 4
        else { return nil }
        let length = Int(plaintext.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard length <= plaintext.count - 4 else { return nil }
        return try? Relay_Content_EncryptedProfile(serializedBytes: plaintext.dropFirst(4).prefix(length))
    }
}

extension MessagingService {
    /// From the chat list: our key if another device's is newer, and any
    /// contact's key we don't have yet (one received since stays). Contacts'
    /// profiles are then fetched, which is what brings photos back after a
    /// restore.
    func importProfileKeys(from snapshot: BackupSnapshot) {
        if let key = snapshot.myProfileKey { adoptMyProfileKey(key, madeAt: snapshot.myProfileKeyAt ?? 0) }
        var added = false
        for (account, key) in snapshot.profileKeys ?? [:] where key.count == 32 && account != credentials.accountId {
            guard peerProfileKey(account) == nil else { continue }
            try? storage.database.run("INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
                                      [.text(Self.peerProfileKeyKV(account)), .blob(key)])
            added = true
        }
        if added { Task { await refreshPeerProfiles(maxAge: 0) } }
    }
}
