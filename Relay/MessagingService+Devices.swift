//
//  MessagingService+Devices.swift
//  Relay
//
//  Linking, labelling and wiping this account's devices, and bookkeeping
//  for peers' devices.
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
    // MARK: - Device linking

    enum LinkingError: LocalizedError {
        case serverMismatch
        case notAuthorized
        var errorDescription: String? {
            switch self {
            case .serverMismatch:
                return "That device is connected to a different Relay server. Point both devices at the same server and try again."
            case .notAuthorized:
                return "Linking was cancelled — biometric confirmation is required to add a device."
            }
        }
    }

    /// Primary side of linking: registers the new device, then seals the shared
    /// identity key and its credentials to the device's ephemeral key. The
    /// identity private key must never be logged.
    func provisionScannedDevice(
        sessionId: String,
        ephemeralPublicKey: Data,
        newDeviceServerURL: String,
        deviceName: String?,
        syncConversations: Bool,
        syncHistory: Bool
    ) async throws {
        // The new device polls the relay it created the session on.
        guard newDeviceServerURL == serverURL.absoluteString else {
            throw LinkingError.serverMismatch
        }
        // Linking shares the account identity, so require user presence.
        guard await BiometricGate.authenticate(reason: "Confirm linking a new device to your Relay account.", requirePasscode: true) else {
            throw LinkingError.notAuthorized
        }
        let password = Self.newDevicePassword()
        let authorization = try await deviceMutationAuthorization(action: "link", targetDeviceId: 0, password: password)
        // The relay stores no device names.
        let deviceId = try await api.linkDevice(password: password, deviceName: nil, authorization: authorization)

        // Until the payload is stored the new device can never sign in, so a
        // failure from here on removes it rather than leaving a keyless row.
        do {
            // Every device of the account presents the same identity.
            let identityData = try keychain.identityKeyPair().serialize()

            var peers: [LinkProvisioningPayload.PeerStub] = []
            let convList = conversations.filter { $0.groupId == nil && !$0.peerAccount.isEmpty }
            if syncConversations {
                peers = convList.prefix(50).map { .init(account: $0.peerAccount, username: $0.peerUsername) }
            }
            var historyId: String?
            var historyKey: Data?
            var historyDigest: Data?
            if syncHistory {
                if let (id, key, digest) = try? await buildAndUploadHistory(conversations: convList) {
                    historyId = id
                    historyKey = key
                    historyDigest = digest
                }
            }

            // Sign a transcript binding the session, the ephemeral key and the
            // credentials, so the new device can reject a replayed or swapped blob.
            let signature = try ProvisioningSignature.sign(
                sessionId: sessionId,
                recipientEphemeralPublicKey: ephemeralPublicKey,
                accountId: credentials.accountId,
                deviceId: deviceId,
                password: password,
                identityKeyPair: identityData
            )
            let payload = LinkProvisioningPayload(
                identityKeyPair: identityData,
                accountId: credentials.accountId,
                username: username,
                deviceId: deviceId,
                password: password,
                serverURL: serverURL.absoluteString,
                peers: peers,
                historyId: historyId,
                historyKey: historyKey,
                historyDigest: historyDigest,
                signature: signature
            )
            let plaintext = try JSONEncoder().encode(payload)
            let blob = try ProvisioningCipher.seal(plaintext, toEphemeralPublicKey: ephemeralPublicKey)
            try await api.storeProvisioningBlob(sessionId: sessionId, blob: blob)
        } catch {
            await removeUnprovisionedDevice(deviceId)
            throw error
        }

        // Record the link in the Relay chat so it can't happen silently.
        postRelayNotice("A new device (device \(deviceId)) was linked to your account. \(Self.untrustedDeviceAdvice)")
    }

    /// Best effort: the relay also reaps devices that never publish keys.
    private func removeUnprovisionedDevice(_ deviceId: UInt32) async {
        do {
            let authorization = try await deviceMutationAuthorization(action: "remove", targetDeviceId: deviceId, password: "")
            try await api.removeDevice(deviceId: deviceId, authorization: authorization)
        } catch {
            log.warning("link: removing the unprovisioned device failed: \(PrivacyRedactor.error(error))")
        }
    }

    /// 32 random bytes, URL-safe base64.
    static func newDevicePassword() -> String {
        var b = Data(count: 32)
        let status = b.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return b.base64URLEncodedString()
    }

    private func buildAndUploadHistory(conversations convList: [Conversation]) async throws -> (String, Data, Data)? {
        var historyEntries: [[String: Any]] = []
        var totalMessages = 0
        for conv in convList.prefix(20) {
            guard !conv.peerAccount.isEmpty,
                  let msgs = try? storage.messages.messages(in: conv.id, limit: 50),
                  !msgs.isEmpty else { continue }
            totalMessages += msgs.count
            if totalMessages > 500 { break }
            let msgArray: [[String: Any]] = msgs.map { m in
                var d: [String: Any] = [
                    "id": m.id,
                    "body": m.body,
                    "timestamp": m.timestamp,
                    "isOutgoing": m.isOutgoing,
                    "status": m.status.rawValue
                ]
                if let r = m.replyTo {
                    d["replyTimestamp"] = r.targetTimestamp
                    d["replyAuthor"] = r.author
                    d["replyText"] = r.text
                }
                return d
            }
            var entry: [String: Any] = ["peer": conv.peerAccount, "messages": msgArray]
            if let u = conv.peerUsername { entry["username"] = u }
            historyEntries.append(entry)
        }
        guard !historyEntries.isEmpty else { return nil }
        let json = try JSONSerialization.data(withJSONObject: historyEntries)
        let sealed = try AttachmentCipher.seal(json)
        let attachmentId = try await api.uploadAttachment(sealed.ciphertext)
        return (attachmentId, sealed.key, sealed.digest)
    }

    /// Imports the history blob the primary uploaded during linking.
    func importHistoryBlob(attachmentId: String, key: Data, digest: Data) async {
        guard let ciphertext = try? await api.downloadAttachment(id: attachmentId) else { return }
        guard let plaintext = try? AttachmentCipher.open(ciphertext, key: key, digest: digest) else { return }
        guard let entries = (try? JSONSerialization.jsonObject(with: plaintext)) as? [[String: Any]] else { return }
        for entry in entries {
            guard let peer = entry["peer"] as? String, !peer.isEmpty else { continue }
            let username = entry["username"] as? String
            let convId = (try? storage.messages.conversation(withPeer: peer, username: username)) ?? ""
            guard !convId.isEmpty else { continue }
            let msgs = entry["messages"] as? [[String: Any]] ?? []
            for m in msgs {
                guard let id = m["id"] as? String,
                      let body = m["body"] as? String,
                      let timestamp = m["timestamp"] as? Int64,
                      let isOutgoing = m["isOutgoing"] as? Bool else { continue }
                let statusStr = m["status"] as? String ?? "received"
                let status = MessageStatus(rawValue: statusStr) ?? .received
                let replyTo: QuotedMessage? = (m["replyTimestamp"] as? Int64).map {
                    QuotedMessage(targetTimestamp: $0, author: m["replyAuthor"] as? String ?? "", text: m["replyText"] as? String ?? "")
                }
                _ = try? storage.messages.insertMessage(
                    id: id, conversationId: convId, isOutgoing: isOutgoing,
                    body: body, timestamp: timestamp, status: status, replyTo: replyTo
                )
            }
            // History is pre-read; don't show imported messages as unread.
            try? storage.messages.markConversationRead(convId)
        }
        refreshConversations()
    }

    // MARK: - Remote wipe

    /// Every device on the account wipes itself on receipt.
    func sendNukeCommand() async throws {
        let creationTimeMs = Int64(Date().timeIntervalSince1970 * 1000)
        let initiatingDeviceId = credentials.deviceId
        // The device auth key is registered through the relay, so it proves
        // nothing to our other devices. They trust only the account identity
        // key's signature, carried in the command id ("<uuid>.<base64url sig>"),
        // which the relay passes through verbatim.
        let nonce = UUID().uuidString
        let identitySignature = try engine.signWithIdentity(Data(nukeIdentityPayload(
            accountId: credentials.accountId, nonce: nonce,
            creationTimeMs: creationTimeMs, initiatingDeviceId: initiatingDeviceId
        ).utf8))
        let commandId = "\(nonce).\(identitySignature.base64URLEncodedString())"
        let payload = nukeCanonicalPayload(
            accountId: credentials.accountId,
            commandId: commandId,
            creationTimeMs: creationTimeMs,
            initiatingDeviceId: initiatingDeviceId
        )
        let publicKey = try keychain.deviceAuthorizationPublicKey()
        try await api.setDeviceAuthorizationKey(publicKey)
        let signature = try keychain.signDeviceAuthorizationPayload(Data(payload.utf8))
        try await api.sendNukeCommand(
            commandId: commandId,
            creationTimeMs: creationTimeMs,
            initiatingDeviceId: initiatingDeviceId,
            signature: signature
        )
    }

    func handleNukeEvent(_ nuke: NukeEvent) async {
        guard nuke.accountId == credentials.accountId else {
            log.warning("nuke: received command for wrong account, ignoring")
            return
        }
        // Reject commands older than 5 minutes.
        let age = Int64(Date().timeIntervalSince1970 * 1000).subtractingReportingOverflow(nuke.creationTimeMs)
        let ageMs = age.partialValue
        guard !age.overflow, ageMs >= -30_000 && ageMs <= 5 * 60 * 1000 else {
            log.warning("nuke: command timestamp out of acceptable range, ignoring")
            return
        }
        // Only our own devices hold the identity private key; the relay doesn't.
        let parts = nuke.commandId.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let signature = Data(base64URLEncoded: parts[1]),
              engine.verifyOwnIdentitySignature(signature, message: Data(nukeIdentityPayload(
                  accountId: nuke.accountId, nonce: parts[0],
                  creationTimeMs: nuke.creationTimeMs, initiatingDeviceId: nuke.initiatingDeviceId
              ).utf8))
        else {
            log.warning("nuke: identity signature missing or invalid, ignoring")
            return
        }
        log.info("nuke: verified command from device \(nuke.initiatingDeviceId), executing wipe")
        await onNukeReceived?()
    }

    func refreshDeviceList() async throws {
        _ = try await api.listDevices()
        // A device was added or removed; the next sync must re-fetch the device list.
        resetSession(withPeer: credentials.accountId)
    }

    private func nukeIdentityPayload(accountId: String, nonce: String, creationTimeMs: Int64, initiatingDeviceId: UInt32) -> String {
        ["relay-nuke-identity-v1", accountId, nonce, String(creationTimeMs), String(initiatingDeviceId)].joined(separator: "\n")
    }

    private func nukeCanonicalPayload(accountId: String, commandId: String, creationTimeMs: Int64, initiatingDeviceId: UInt32) -> String {
        ["relay-nuke-v1", accountId, commandId, String(creationTimeMs), String(initiatingDeviceId)].joined(separator: "\n")
    }

    /// First step of signing out, so no ghost device keeps collecting messages.
    func removeThisDeviceFromServer() async throws {
        isRemovingSelf = true
        let authorization = try await deviceMutationAuthorization(
            action: "remove", targetDeviceId: credentials.deviceId, password: "")
        try await api.removeDevice(deviceId: credentials.deviceId, authorization: authorization)
    }

    // MARK: - Device labels

    /// This device's stored label, or a model-only one.
    var myDeviceLabel: DeviceLabel {
        deviceLabel(forDevice: credentials.deviceId)
            ?? DeviceLabel(model: DeviceModel.current, region: "", updatedAt: 0)
    }

    /// Labels are shared sealed between our own devices; the relay never sees them.
    func deviceLabel(forDevice deviceId: UInt32) -> DeviceLabel? {
        guard let data = (try? storage.database.query(
            "SELECT value FROM kv WHERE key = ?", [.text("devinfo:\(deviceId)")]
        ))?.first?.first?.data else { return nil }
        return try? JSONDecoder().decode(DeviceLabel.self, from: data)
    }

    /// Shares this device's label (model and approximate region) with our other
    /// devices. Without `force`, only when changed or over a day old.
    func publishDeviceLabel(force: Bool) async {
        let previous = deviceLabel(forDevice: credentials.deviceId)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        // Check freshness before taking a location fix: the geocoder is
        // Apple's, so don't send it coordinates on every launch.
        if !force, let previous, now - previous.updatedAt < 86_400_000,
           previous.model == DeviceModel.current {
            return
        }
        let regionEnabled = DeviceRegion.shared.isEnabled
        let region = await DeviceRegion.shared.currentRegion()
        var label = DeviceLabel(model: DeviceModel.current, region: region, updatedAt: now)
        // Keep the last known region unless the user turned regions off.
        if label.region.isEmpty, regionEnabled, let previous { label.region = previous.region }
        let unchanged = previous.map { $0.model == label.model && $0.region == label.region } ?? false
        let fresh = previous.map { now - $0.updatedAt < 86_400_000 } ?? false
        if unchanged && fresh && !force { return }
        if let data = try? JSONEncoder().encode(label) {
            try? storage.database.run(
                "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
                [.text("devinfo:\(credentials.deviceId)"), .blob(data)])
        }
        var content = Relay_Content_Content()
        content.deviceInfo.model = label.model
        content.deviceInfo.region = label.region
        content.deviceInfo.updatedAt = label.updatedAt
        await sendSyncToOwnDevices(content: content, peer: "", timestamp: now)
    }

    func removeLinkedDevice(deviceId: UInt32) async throws {
        let authorization = try await deviceMutationAuthorization(action: "remove", targetDeviceId: deviceId, password: "")
        try await api.removeDevice(deviceId: deviceId, authorization: authorization)
        postRelayNotice("Device \(deviceId) was unlinked from your account. It no longer gets new messages, but it still holds your account's security key; if someone else may have it, sign in to your account again on this iPhone to make a new one.")
    }

    private func deviceMutationAuthorization(action: String, targetDeviceId: UInt32, password: String) async throws -> RelayKit.DeviceMutationAuthorization {
        let publicKey = try keychain.deviceAuthorizationPublicKey()
        try await api.setDeviceAuthorizationKey(publicKey)
        let list = try await api.deviceList()
        let version = list.deviceListVersion
        let payload = [
            "relay-device-list-v1",
            credentials.accountId,
            String(version),
            action,
            String(targetDeviceId),
            password
        ].joined(separator: "\n")
        let signature = try keychain.signDeviceAuthorizationPayload(Data(payload.utf8))
        return RelayKit.DeviceMutationAuthorization(
            expectedVersion: version,
            signerDeviceId: credentials.deviceId,
            signature: signature.base64EncodedString()
        )
    }

    // MARK: - Peer device bookkeeping

    struct PeerDevice: Codable {
        let id: UInt32
        let mailboxId: String?
        let registrationId: UInt32
    }

    func knownDevices(ofPeer account: String) -> [PeerDevice] {
        guard let data = try? storage.database.query(
            "SELECT value FROM kv WHERE key = ?", [.text("peer-devices:\(account)")]
        ).first?.first?.data else { return [] }
        return (try? JSONDecoder().decode([PeerDevice].self, from: data)) ?? []
    }

    func storeKnownDevices(_ devices: [PeerDevice], ofPeer account: String) throws {
        try storage.database.run(
            "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
            [.text("peer-devices:\(account)"), .blob(try JSONEncoder().encode(devices))]
        )
    }
}
