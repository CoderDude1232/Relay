//
//  MessagingService+Attachments.swift
//  Relay
//
//  Sending and downloading attachments.
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
    // MARK: - Attachments

    /// Plaintext, held only in memory.
    struct PendingAttachment {
        let data: Data
        let contentType: String
        let filename: String?
        let width: Int
        let height: Int
    }

    /// Caches the ciphertext; decryption happens in memory at display time.
    func downloadAttachment(_ attachment: StoredAttachment, in conversationId: String) async {
        if attachmentStore.exists(attachment.id) {
            try? storage.messages.markAttachmentDownloaded(id: attachment.id)
            return
        }
        let wifiOnly = UserDefaults.standard.bool(forKey: "relay.wifiOnlyDownload")
        if wifiOnly && !isOnWifi { return }
        do {
            let ciphertext = try await api.downloadAttachment(id: attachment.id)
            try attachmentStore.write(ciphertext, for: attachment.id)
            try storage.messages.markAttachmentDownloaded(id: attachment.id)
            refreshActiveMessages(ifShowing: conversationId)
        } catch {
            log.error("attachment download failed: \(PrivacyRedactor.error(error))")
        }
    }

    /// Deletes cached ciphertext for received attachments, which can be fetched
    /// again. Outgoing and Note to Self media may exist only here, so they stay.
    func clearCachedMedia() async throws {
        let rows = try storage.database.query(
            """
            SELECT a.id FROM attachments a
            JOIN messages m ON a.message_id = m.id
            JOIN conversations c ON m.conversation_id = c.id
            WHERE a.downloaded = 1 AND m.is_outgoing = 0 AND c.peer_account != ?
            """,
            [.text(noteToSelfAccount)]
        )
        for row in rows {
            guard let id = row.first?.string else { continue }
            attachmentStore.delete(id)
            try storage.database.run("UPDATE attachments SET downloaded = 0 WHERE id = ?", [.text(id)])
        }
        if let active = activeConversationId { refreshActiveMessages(ifShowing: active) }
    }

    /// For MediaGalleryView, which can open while another conversation is active.
    func allMessages(in conversationId: String) throws -> [StoredMessage] {
        try storage.messages.messages(in: conversationId)
    }

    /// View-once media is never forwarded.
    func forward(_ message: StoredMessage, to conversationId: String) async {
        guard !message.body.hasPrefix(Self.viewOncePrefix) else { return }
        var pending: [PendingAttachment] = []
        for attachment in message.attachments {
            if !attachmentStore.exists(attachment.id) {
                await downloadAttachment(attachment, in: message.conversationId)
            }
            guard let data = attachmentPlaintext(attachment) else { continue }
            pending.append(PendingAttachment(
                data: data, contentType: attachment.contentType, filename: attachment.filename,
                width: attachment.width, height: attachment.height
            ))
        }
        guard !message.body.isEmpty || !pending.isEmpty else { return }
        await sendMessage(message.body, in: conversationId, attachments: pending)
    }

    static let viewOncePrefix = "~once~"
    /// Also used by MessageStore's chat-list preview and the NSE.
    static let stickerMarker = "__sticker__"

    func attachmentPlaintext(_ attachment: StoredAttachment) -> Data? {
        guard let ciphertext = try? attachmentStore.read(attachment.id) else { return nil }
        return try? AttachmentCipher.open(ciphertext, key: attachment.key, digest: attachment.digest)
    }

    func sendReceipt(
        _ type: Relay_Content_ReceiptMessage.TypeEnum,
        timestamps: [Int64],
        toPeer account: String,
        groupId: String? = nil
    ) async {
        // Nothing tells a requester (or someone we blocked) their message
        // arrived or was seen.
        if isBlocked(account) { return }
        if let groupId {
            if conversations.first(where: { $0.groupId == groupId })?.isRequest == true { return }
        } else if (try? storage.messages.isMessageRequest(peer: account)) == true {
            return
        }
        // Not the instant the message arrived (see afterTimingJitter); merged
        // with others for the same recipient while it waits.
        let key = ReceiptKey(type: type, peer: account, groupId: groupId)
        if pendingReceipts[key] != nil {
            pendingReceipts[key]?.append(contentsOf: timestamps)
            return
        }
        pendingReceipts[key] = timestamps
        afterTimingJitter(seconds: 1...6) { [weak self] in
            guard let self, let batch = self.pendingReceipts.removeValue(forKey: key), !batch.isEmpty else { return }
            // Blocked or turned into a request while waiting: nothing goes out.
            if self.isBlocked(account) { return }
            if let groupId {
                if self.conversations.first(where: { $0.groupId == groupId })?.isRequest == true { return }
            } else if (try? self.storage.messages.isMessageRequest(peer: account)) == true {
                return
            }
            var content = Relay_Content_Content()
            content.receipt.type = type
            content.receipt.messageTimestamps = batch
            if let groupId { content.groupID = groupId }
            do {
                try await self.sendContent(
                    try content.serializedData(),
                    toPeer: account,
                    clientTimestamp: Int64(Date().timeIntervalSince1970 * 1000),
                    silent: true
                )
            } catch {
                self.log.warning("receipt send failed: \(PrivacyRedactor.error(error))")
            }
        }
    }

    /// On a device mismatch, re-fetches bundles and retries once.
    func sendContent(
        _ plaintext: Data,
        toPeer account: String,
        clientTimestamp: Int64,
        ephemeral: Bool = false,
        silent: Bool = false
    ) async throws {
        // Receipts (silent) and typing (ephemeral) carry nothing; they may go
        // out while a safety-number change is pending.
        if !ephemeral && !silent {
            try requireAcknowledgedIdentity(forPeer: account)
        }
        // Pad ephemeral frames too, so size doesn't reveal the message kind.
        let payloadPlaintext = try ContentPadding.pad(plaintext)
        // Fail closed: a missing access key (or a relay withholding it) must not
        // fall back to an authenticated send that reveals the sender.
        if sealedSenderEnabled {
            guard await recipientSupportsSealed(account) else {
                throw MessagingError.recipientCannotReceivePrivately
            }
            try await sendContentSealed(
                payloadPlaintext, toPeer: account,
                clientTimestamp: clientTimestamp, ephemeral: ephemeral, silent: silent
            )
            return
        }
        guard socket != nil else { throw RelayWebSocketError.notConnected }
        var devices = try await knownMailboxDevices(ofPeer: account)
        // The server reports every other device as missing, including ones we
        // just delivered to, so the retry must skip round-1 devices.
        let firstRoundIds = Set(devices.map { $0.id })
        var payloads = try buildMailboxPayloads(payloadPlaintext, forPeer: account, devices: devices)
        var outcome = try await sendMailboxPayloads(
            payloads,
            clientTimestamp: clientTimestamp,
            ephemeral: ephemeral,
            silent: silent
        )
        if case .mismatchedDevices(let missing, _, let stale) = outcome {
            try await refreshSessions(withPeer: account)
            if !ephemeral && !silent {
                try requireAcknowledgedIdentity(forPeer: account)
            }
            devices = try await knownMailboxDevices(ofPeer: account)
            // Newly discovered devices plus stale ones; re-sending to round-1
            // devices would duplicate.
            let retryIds = Set(missing).subtracting(firstRoundIds).union(Set(stale))
            if !retryIds.isEmpty {
                let retryDevices = devices.filter { retryIds.contains($0.id) }
                payloads = try buildMailboxPayloads(payloadPlaintext, forPeer: account, devices: retryDevices)
                outcome = try await sendMailboxPayloads(
                    payloads,
                    clientTimestamp: clientTimestamp,
                    ephemeral: ephemeral,
                    silent: silent
                )
                // Remaining missing/stale devices that were all addressed count as success.
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
            throw RelayAPIError.http(status: 0, message: "send rejected: \(outcome)")
        }
    }

    /// True once we know their access key; fetches the bundle once if needed.
    func recipientSupportsSealed(_ account: String) async -> Bool {
        if knownAccessKey(account) != nil { return true }
        try? await refreshSessions(withPeer: account)
        return knownAccessKey(account) != nil
    }

    /// Unlike the WebSocket path there's no device-mismatch verdict, so this
    /// relies on the local device list (kept current by `DeviceListChanged` and
    /// bundle refreshes).
    func sendContentSealed(
        _ plaintext: Data,
        toPeer account: String,
        clientTimestamp: Int64,
        ephemeral: Bool,
        silent: Bool = false
    ) async throws {
        let certificate = try await senderCertificate()
        if knownAccessKey(account) == nil {
            try await refreshSessions(withPeer: account)
        }
        guard knownAccessKey(account) != nil else {
            throw RelayAPIError.http(status: 403, message: "recipient has not enabled sealed sender")
        }

        // A 403 usually means a rotated mailbox or access key: refresh once and
        // retry only the failed devices.
        let devices = try await knownMailboxDevices(ofPeer: account)
        var failed = try await sealedSendPass(
            plaintext, toPeer: account, devices: devices, certificate: certificate,
            clientTimestamp: clientTimestamp, ephemeral: ephemeral, silent: silent
        )
        guard !failed.isEmpty else { return }

        try await refreshSessions(withPeer: account)
        let refreshedDevices = try await knownMailboxDevices(ofPeer: account)
        let failedIds = Set(failed.map { $0.id })
        let retryDevices = refreshedDevices.filter { failedIds.contains($0.id) }
        failed = try await sealedSendPass(
            plaintext, toPeer: account, devices: retryDevices, certificate: certificate,
            clientTimestamp: clientTimestamp, ephemeral: ephemeral, silent: silent
        )
        if !failed.isEmpty {
            throw RelayAPIError.http(status: 403, message: "sealed delivery rejected")
        }
    }

    /// Returns the devices that got a retryable 403; other errors throw.
    private func sealedSendPass(
        _ plaintext: Data,
        toPeer account: String,
        devices: [PeerDevice],
        certificate: Data,
        clientTimestamp: Int64,
        ephemeral: Bool,
        silent: Bool = false
    ) async throws -> [PeerDevice] {
        // Re-read each pass so a refresh in between takes effect.
        guard let accessKey = knownAccessKey(account) else { return devices }
        var failed: [PeerDevice] = []
        for device in devices {
            guard let mailboxId = device.mailboxId, !mailboxId.isEmpty else { continue }
            let address = try ProtocolAddress(name: account, deviceId: device.id)
            if !(try engine.hasSession(with: address)) {
                try await refreshSessions(withPeer: account)
            }
            let sealed = try engine.sealedEncrypt(plaintext, for: address, senderCertificate: certificate)
            do {
                _ = try await api.sendSealed(
                    mailboxId: mailboxId,
                    type: .message,
                    content: sealed,
                    accessKey: accessKey,
                    ephemeral: ephemeral,
                    silent: silent,
                    clientTimestamp: clientTimestamp
                )
            } catch let RelayAPIError.http(status, _) where status == 403 {
                failed.append(device)
            }
        }
        return failed
    }

    func buildMailboxPayloads(
        _ plaintext: Data,
        forPeer account: String,
        devices: [PeerDevice]
    ) throws -> [(mailboxId: String, payload: DeviceMessagePayload)] {
        try devices.map { device in
            guard let mailboxId = device.mailboxId, !mailboxId.isEmpty else {
                throw RelayAPIError.malformedResponse
            }
            let address = try ProtocolAddress(name: account, deviceId: device.id)
            return (
                mailboxId,
                DeviceMessagePayload(
                    deviceId: device.id,
                    registrationId: device.registrationId,
                    message: try engine.encrypt(plaintext, for: address)
                )
            )
        }
    }

    func knownAccessKey(_ account: String) -> Data? {
        if let key = peerAccessKeys[account] { return key }
        guard let data = (try? storage.database.query(
            "SELECT value FROM kv WHERE key = ?", [.text("ak:\(account)")]
        ).first?.first?.data) ?? nil, data.count == 32 else { return nil }
        peerAccessKeys[account] = data
        return data
    }

    func rememberAccessKey(_ key: Data?, for account: String) {
        peerAccessKeys[account] = key
        if let key {
            try? storage.database.run("INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
                                      [.text("ak:\(account)"), .blob(key)])
        } else {
            try? storage.database.run("DELETE FROM kv WHERE key = ?", [.text("ak:\(account)")])
        }
    }

    /// Anonymous bundle fetch; nil (after forgetting the key) when the relay
    /// rejects the access key, so the caller falls back to the signed fetch.
    private func fetchBundlesAnonymously(_ account: String, accessKey: Data) async throws -> [PeerPreKeyBundle]? {
        do {
            return try await api.fetchPreKeyBundlesSealed(account: account, accessKey: accessKey)
        } catch RelayAPIError.http(status: 403, _) {
            rememberAccessKey(nil, for: account)
            return nil
        }
    }

    func refreshSessions(withPeer account: String) async throws {
        let bundles: [PeerPreKeyBundle]
        // With an access key the fetch is anonymous. Contacts hand us theirs in
        // their profile update; for someone we haven't heard from, look up their
        // certificate username in the blinded directory to get it. A 403 means
        // the key was rotated. The signed fetch is the last resort, for an
        // older client that isn't in the directory and hasn't sent a key.
        // At most one directory lookup per refresh (they count against a rate limit).
        var lookedUp = false
        if account != credentials.accountId, knownAccessKey(account) == nil,
           let username = cachedUsername(account) {
            lookedUp = true
            if let resolved = try? await resolveAccount(username: username), resolved != account {
                log.info("directory username now belongs to a different account; using the signed fetch")
            }
        }
        if account != credentials.accountId, let known = knownAccessKey(account),
           let anonymous = try await fetchBundlesAnonymously(account, accessKey: known) {
            bundles = anonymous
        } else if account != credentials.accountId, !lookedUp, let username = cachedUsername(account),
                  (try? await resolveAccount(username: username)) == account,
                  let fresh = knownAccessKey(account),
                  let anonymous = try await fetchBundlesAnonymously(account, accessKey: fresh) {
            // The key was rotated (403): a fresh one from the directory keeps the
            // fetch anonymous. The signed fetch below names us to the relay, so
            // it's only for accounts the directory can't resolve.
            bundles = anonymous
        } else {
            let fetched = try await api.fetchPreKeyBundlesWithAccessKey(account: account)
            bundles = fetched.bundles
            if let accessKey = fetched.accessKey {
                rememberAccessKey(accessKey, for: account)
            }
        }
        var devices: [PeerDevice] = []
        // Trust on first use is per account, not per device: a new device id
        // alone must never approve keys stored earlier (e.g. one a forged
        // incoming message planted for a fake device).
        let firstContact = try account != credentials.accountId
            && acknowledgedIdentities(forPeer: account) == nil
        for bundle in bundles {
            // Our own account's bundles include this device, and processing a
            // session to self throws, which would abort the whole refresh.
            if account == credentials.accountId && bundle.deviceId == credentials.deviceId {
                continue
            }
            let address = try ProtocolAddress(name: account, deviceId: bundle.deviceId)
            if account == credentials.accountId {
                // A device on our account with a different identity key wasn't
                // provisioned by us; never sync to it.
                guard bundle.identityKey == (try engine.identityKey()) else {
                    noteForeignOwnDevice(bundle.deviceId)
                    continue
                }
            } else {
                try guardIdentityReplacement(bundle.identityKey, peer: account, address: address)
            }
            // Always re-process, so a reinstalled peer or corrupt session gets a
            // fresh session even when one exists.
            try engine.processPeerBundle(bundle, from: address)
            devices.append(PeerDevice(id: bundle.deviceId, mailboxId: bundle.mailboxId, registrationId: bundle.registrationId))
        }
        try storeKnownDevices(devices, ofPeer: account)
        if account != credentials.accountId, !devices.isEmpty {
            try storage.signalStore.pruneIdentities(address: account, keepingDeviceIds: Set(devices.map(\.id)))
        }
        if firstContact {
            try acknowledgeCurrentIdentity(forPeer: account)
        }
    }

    /// One-time Relay chat notice about a device on our account that doesn't
    /// hold our identity key. It receives none of our messages.
    private func noteForeignOwnDevice(_ deviceId: UInt32) {
        log.warning("own-account device with a foreign identity key; excluded from sync")
        let key = "relay.foreignOwnDevice.\(deviceId)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let id = ensureRelayAccount()
        guard !id.isEmpty else { return }
        insertRelayMessage(
            "A device on your account (device \(deviceId)) isn't using your account's security key, so it won't receive your messages. If you didn't link it, remove it in Profile → Linked Devices and change your password.",
            conversationId: id)
    }

    func knownMailboxDevices(ofPeer account: String) async throws -> [PeerDevice] {
        var devices = knownDevices(ofPeer: account)
        if devices.isEmpty || devices.contains(where: { ($0.mailboxId ?? "").isEmpty }) {
            try await refreshSessions(withPeer: account)
            devices = knownDevices(ofPeer: account)
        }
        guard !devices.isEmpty, !devices.contains(where: { ($0.mailboxId ?? "").isEmpty }) else {
            throw RelayAPIError.malformedResponse
        }
        return devices
    }

    func sendMailboxPayloads(
        _ payloads: [(mailboxId: String, payload: DeviceMessagePayload)],
        clientTimestamp: Int64,
        ephemeral: Bool = false,
        silent: Bool = false
    ) async throws -> SendOutcome {
        guard let socket else { throw RelayWebSocketError.notConnected }
        var missing: [UInt32] = []
        var extra: [UInt32] = []
        var stale: [UInt32] = []
        for entry in payloads {
            let outcome = try await socket.send(
                to: entry.mailboxId,
                messages: [entry.payload],
                clientTimestamp: clientTimestamp,
                ephemeral: ephemeral,
                silent: silent
            )
            switch outcome {
            case .ok:
                break
            case .mismatchedDevices(let m, let e, let s):
                // Keep going; later devices still need addressing.
                missing.append(contentsOf: m)
                extra.append(contentsOf: e)
                stale.append(contentsOf: s)
            default:
                return outcome
            }
        }
        if missing.isEmpty && extra.isEmpty && stale.isEmpty {
            return .ok(serverTimestamp: 0)
        }
        return .mismatchedDevices(missing: missing, extra: extra, stale: stale)
    }

    /// Forces the next send to re-fetch bundles and rebuild sessions.
    func resetSession(withPeer account: String) {
        try? storage.database.run(
            "DELETE FROM kv WHERE key = ?", [.text("peer-devices:\(account)")]
        )
    }
}
