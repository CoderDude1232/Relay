//
//  MessagingService.swift
//  Relay
//
//  The orchestrator: glues CryptoCore (encrypt/decrypt), SecureStorage
//  (sessions + history) and RelayKit (REST/WebSocket) together. Owns the
//  connection loop, the incoming-envelope pipeline, receipts, and the
//  per-device fan-out with mismatch retry.
//

import CryptoCore
import Foundation
import LibSignalClient
import Observation
import RelayCore
import RelayKit
import SwiftProtobuf
import SecureStorage
import UIKit
import os

@Observable
final class MessagingService {
    enum ConnectionState: Equatable {
        case disconnected, connecting, connected
    }

    let credentials: RelayCredentials
    let serverURL: URL
    /// Our own username; nil for accounts saved before it was recorded.
    let username: String?
    /// Shared, certificate-pinned session for REST and the WebSocket.
    private let session: URLSession

    private(set) var conversations: [Conversation] = []
    private(set) var activeMessages: [StoredMessage] = []
    private(set) var activeConversationId: String?
    private(set) var connectionState: ConnectionState = .disconnected
    /// Whether the peer of the currently open conversation is typing.
    private(set) var peerTyping: Bool = false

    private let storage: SecureStore
    private let engine: CryptoEngine
    private let processor: EnvelopeProcessor
    private let api: RelayAPIClient
    private let maintainer = PreKeyMaintainer()
    private let attachmentStore = AttachmentBlobStore(appGroupId: AppModel.appGroupId)
    private let allocator: KVPreKeyIdAllocator
    private var socket: RelayWebSocket?
    private var connectionTask: Task<Void, Never>?
    private var typingResetTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.relaytextingapp.Relay", category: "messaging")

    init(credentials: RelayCredentials, serverURL: URL, username: String?, storage: SecureStore, session: URLSession) throws {
        self.credentials = credentials
        self.serverURL = serverURL
        self.username = username
        self.storage = storage
        self.session = session
        self.engine = try storage.makeCryptoEngine(
            accountId: credentials.accountId,
            deviceId: credentials.deviceId
        )
        self.processor = EnvelopeProcessor(storage: storage, engine: engine)
        self.api = RelayAPIClient(baseURL: serverURL, credentials: credentials, session: session)
        self.allocator = KVPreKeyIdAllocator(database: storage.database)
        refreshConversations()
    }

    // MARK: - Lifecycle

    /// Registers this device's APNs token with the relay so it can wake us
    /// for offline messages. Best-effort — messaging works without it.
    func uploadPushToken(_ token: String) async {
        do {
            try await api.setAPNSToken(token)
        } catch {
            log.warning("apns token upload failed: \(error)")
        }
    }

    /// Uploads the first key publication after registration.
    func publishInitialKeys() async throws {
        try await maintainer.publishInitialKeys(api: api, engine: engine, allocator: allocator)
    }

    func start() {
        guard connectionTask == nil else { return }
        connectionTask = Task { await runConnectionLoop() }
    }

    func stop() {
        connectionTask?.cancel()
        connectionTask = nil
        let socket = socket
        self.socket = nil
        guard let socket else { return }
        // Hold a short background-task assertion so iOS keeps us alive long
        // enough to actually send the WebSocket close — otherwise the relay
        // may keep this device "online" (up to its ~60s pong timeout) and
        // never push offline messages.
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "relay-ws-close")
        Task {
            await socket.disconnect()
            await MainActor.run {
                if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
            }
        }
    }

    private func runConnectionLoop() async {
        var backoffSeconds = 1.0
        while !Task.isCancelled {
            connectionState = .connecting
            let socket = RelayWebSocket(baseURL: serverURL, credentials: credentials, session: session)
            self.socket = socket
            for await event in await socket.connect() {
                switch event {
                case .queueDrained:
                    connectionState = .connected
                    backoffSeconds = 1.0
                    do {
                        try await maintainer.replenishIfNeeded(api: api, engine: engine, allocator: allocator)
                    } catch {
                        log.warning("prekey replenishment failed: \(error)")
                    }
                case .envelope(let envelope):
                    await handleEnvelope(envelope)
                case .disconnected:
                    break
                }
            }
            self.socket = nil
            connectionState = .disconnected
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(backoffSeconds))
            backoffSeconds = min(backoffSeconds * 2, 30)
        }
    }

    // MARK: - Incoming pipeline

    private func handleEnvelope(_ envelope: IncomingEnvelope) async {
        // Ack unconditionally once processing finishes: an envelope that
        // fails to decrypt would otherwise redeliver forever. Dedup and
        // ratchet state make retrying it pointless anyway.
        defer {
            let socket = socket
            Task { try? await socket?.ack(envelopeId: envelope.id) }
        }
        do {
            // The shared processor decrypts + stores exactly once (same path
            // the NSE uses). We handle the app-only follow-ups it reports.
            let result = try processor.process(envelope)

            if let timestamp = result.sideEffects.deliveryReceiptTimestamp {
                await sendReceipt(.delivery, timestamps: [timestamp], toPeer: envelope.senderAccount)
            }
            if let account = result.sideEffects.backfillUsernameForAccount,
               let conversationId = result.conversationId {
                backfillUsernameIfNeeded(conversationId: conversationId, account: account)
            }
            if let typingStarted = result.typingStarted {
                applyPeerTyping(started: typingStarted, peerAccount: result.peerAccount)
            }
            if result.outcome == .stored, let conversationId = result.conversationId {
                clearPeerTyping(for: conversationId) // a real message ends typing
            }
            if let conversationId = result.conversationId {
                refreshConversations()
                refreshActiveMessages(ifShowing: conversationId)
            }
            if let groupUpdate = result.groupUpdate {
                await handleGroupUpdate(groupUpdate)
            }
        } catch {
            log.error("failed to process envelope \(envelope.id): \(error)")
        }
    }

    // MARK: - Sending

    /// Starts (or reopens) a conversation with a username; resolves it to
    /// an account id via the relay.
    func startConversation(username: String) async throws -> String {
        let account = try await api.lookupAccount(username: username)
        let id = try storage.messages.conversation(withPeer: account, username: username)
        refreshConversations()
        return id
    }

    func sendMessage(
        _ text: String,
        in conversationId: String,
        replyTo: QuotedMessage? = nil,
        attachments pending: [PendingAttachment] = []
    ) async {
        if let group = try? groupForConversation(conversationId) {
            await sendGroupMessage(text, in: conversationId, group: group, replyTo: replyTo, attachments: pending)
            return
        }
        guard let peer = try? peerAccount(for: conversationId) else { return }
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let localId = UUID().uuidString
        do {
            // Encrypt each attachment with a fresh key, upload the ciphertext,
            // and cache it locally so the sender can view it without a fetch.
            var storedAttachments: [StoredAttachment] = []
            var pointers: [Relay_Content_AttachmentPointer] = []
            for item in pending {
                let sealed = try AttachmentCipher.seal(item.data)
                let id = try await api.uploadAttachment(sealed.ciphertext)
                try? attachmentStore.write(sealed.ciphertext, for: id)
                storedAttachments.append(StoredAttachment(
                    id: id, key: sealed.key, digest: sealed.digest,
                    contentType: item.contentType, size: Int64(sealed.ciphertext.count),
                    filename: item.filename, width: item.width, height: item.height,
                    isDownloaded: true
                ))
                var pointer = Relay_Content_AttachmentPointer()
                pointer.id = id
                pointer.key = sealed.key
                pointer.digest = sealed.digest
                pointer.contentType = item.contentType
                pointer.size = UInt64(sealed.ciphertext.count)
                if let filename = item.filename { pointer.filename = filename }
                pointer.width = UInt32(item.width)
                pointer.height = UInt32(item.height)
                pointers.append(pointer)
            }

            try storage.messages.insertMessage(
                id: localId,
                conversationId: conversationId,
                isOutgoing: true,
                body: text,
                timestamp: timestamp,
                status: .sending,
                replyTo: replyTo,
                attachments: storedAttachments
            )
            refreshConversations()
            refreshActiveMessages(ifShowing: conversationId)

            var content = Relay_Content_Content()
            content.text.body = text
            content.text.timestamp = timestamp
            if let replyTo {
                content.text.quote.targetTimestamp = replyTo.targetTimestamp
                content.text.quote.author = replyTo.author
                content.text.quote.text = replyTo.text
            }
            content.text.attachments = pointers
            try await sendContent(try content.serializedData(), toPeer: peer, clientTimestamp: timestamp)
            try storage.messages.updateStatus(messageId: localId, status: .sent)
        } catch {
            log.error("send failed: \(error)")
            try? storage.messages.updateStatus(messageId: localId, status: .failed)
        }
        refreshActiveMessages(ifShowing: conversationId)
    }

    // MARK: - Groups

    /// Sentinel sender for locally-inserted group system lines.
    static let systemSender = "__system__"

    /// The stored group backing a conversation (nil for 1:1), for the UI.
    func group(for conversationId: String) -> StoredGroup? {
        try? groupForConversation(conversationId)
    }

    /// A human name for an account: "You" for self, the known username from a
    /// 1:1 conversation if we have one, else a short account prefix.
    func displayName(forAccount account: String) -> String {
        if account == credentials.accountId { return "You" }
        if let cached = cachedUsername(account) { return cached }
        if let name = (try? storage.database.query(
            "SELECT peer_username FROM conversations WHERE peer_account = ?", [.text(account)]
        ).first?.first?.string) ?? nil { return name }
        return String(account.prefix(8))
    }

    private func cachedUsername(_ account: String) -> String? {
        (try? storage.database.query(
            "SELECT value FROM kv WHERE key = ?", [.text("un:\(account)")]
        ).first?.first?.data).flatMap { $0 }.map { String(decoding: $0, as: UTF8.self) }
    }

    private func cacheUsername(_ account: String, _ username: String) {
        try? storage.database.run(
            "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
            [.text("un:\(account)"), .blob(Data(username.utf8))]
        )
    }

    /// Resolves any unknown account ids to usernames via the relay, caching
    /// them (and updating the 1:1 conversation title if one exists). Cheap and
    /// idempotent — skips accounts already known.
    func resolveUsernames(_ accounts: [String]) async {
        var changed = false
        for account in Set(accounts) where account != credentials.accountId {
            if cachedUsername(account) != nil { continue }
            guard let username = try? await api.lookupUsername(account: account) else { continue }
            cacheUsername(account, username)
            if existingConversation(withPeer: account) != nil {
                _ = try? storage.messages.conversation(withPeer: account, username: username)
            }
            changed = true
        }
        if changed {
            refreshConversations()
            if let conversationId = activeConversationId {
                refreshActiveMessages(ifShowing: conversationId)
            }
        }
    }

    /// Inserts a centered "system" line (e.g. "Alice added Bob") into a group.
    private func insertSystemLine(_ text: String, inGroup groupId: String) {
        guard let conversationId = (try? storage.messages.groupConversationId(groupId: groupId)) ?? nil else { return }
        try? storage.messages.insertMessage(
            id: UUID().uuidString, conversationId: conversationId, isOutgoing: false,
            body: text, timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            status: .received, senderAccount: Self.systemSender
        )
        refreshConversations()
        refreshActiveMessages(ifShowing: conversationId)
    }

    /// The stored group backing a conversation, or nil for 1:1.
    private func groupForConversation(_ conversationId: String) throws -> StoredGroup? {
        guard let groupId = try storage.database.query(
            "SELECT group_id FROM conversations WHERE id = ?", [.text(conversationId)]
        ).first?.first?.string else { return nil }
        return try storage.messages.group(id: groupId)
    }

    /// Creates a group (server holds the roster), sets up our sender key,
    /// and notifies members to sync. Returns the local conversation id.
    func createGroup(name: String, memberUsernames: [String]) async throws -> String {
        var members: [String] = []
        for username in memberUsernames {
            let account = try await api.lookupAccount(username: username)
            members.append(account)
            try? await refreshSessions(withPeer: account) // need pairwise sessions for SKDM/control
        }
        let gs = try await api.createGroup(name: name, members: members)
        try storage.messages.upsertGroup(id: gs.id, name: gs.name, distributionId: gs.distributionId, revision: gs.revision, members: gs.members)
        refreshConversations()
        if let stored = try storage.messages.group(id: gs.id) {
            try? await distributeSenderKeyIfNeeded(group: stored)
            await sendGroupUpdate(.create, group: stored, target: "")
        }
        insertSystemLine("You created “\(name)”", inGroup: gs.id)
        await resolveUsernames(gs.members)
        return try storage.messages.groupConversationId(groupId: gs.id) ?? ""
    }

    func addGroupMember(username: String, toGroup groupId: String) async throws {
        let account = try await api.lookupAccount(username: username)
        try? await refreshSessions(withPeer: account)
        let gs = try await api.addGroupMember(groupId: groupId, account: account)
        try storage.messages.upsertGroup(id: gs.id, name: gs.name, distributionId: gs.distributionId, revision: gs.revision, members: gs.members)
        refreshConversations()
        if let stored = try storage.messages.group(id: gs.id) {
            try? await distributeSenderKeyIfNeeded(group: stored) // reaches the new member
            await sendGroupUpdate(.add, group: stored, target: account)
        }
        insertSystemLine("You added \(username)", inGroup: groupId)
    }

    func removeGroupMember(_ account: String, fromGroup groupId: String) async throws {
        let gs = try await api.removeGroupMember(groupId: groupId, account: account) // server rotates distributionId
        try storage.messages.upsertGroup(id: gs.id, name: gs.name, distributionId: gs.distributionId, revision: gs.revision, members: gs.members)
        refreshConversations()
        if let stored = try storage.messages.group(id: gs.id) {
            try? await distributeSenderKeyIfNeeded(group: stored) // fresh epoch → redistribute to remaining
            await sendGroupUpdate(.remove, group: stored, target: account)
        }
        insertSystemLine("You removed \(displayName(forAccount: account))", inGroup: groupId)
    }

    func leaveGroup(_ groupId: String) async throws {
        let gs = try await api.removeGroupMember(groupId: groupId, account: credentials.accountId)
        let remaining = StoredGroup(id: gs.id, name: gs.name, distributionId: gs.distributionId, revision: gs.revision, members: gs.members)
        await sendGroupUpdate(.leave, group: remaining, target: credentials.accountId)
        try storage.messages.upsertGroup(id: gs.id, name: gs.name, distributionId: gs.distributionId, revision: gs.revision, members: gs.members)
        refreshConversations()
        insertSystemLine("You left", inGroup: gs.id)
    }

    private func sendGroupMessage(
        _ text: String, in conversationId: String, group: StoredGroup,
        replyTo: QuotedMessage?, attachments pending: [PendingAttachment]
    ) async {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let localId = UUID().uuidString
        guard let distributionId = UUID(uuidString: group.distributionId) else { return }
        do {
            try await distributeSenderKeyIfNeeded(group: group)
            let (storedAttachments, pointers) = try await encryptAttachments(pending)

            try storage.messages.insertMessage(
                id: localId, conversationId: conversationId, isOutgoing: true,
                body: text, timestamp: timestamp, status: .sending,
                replyTo: replyTo, attachments: storedAttachments,
                senderAccount: credentials.accountId
            )
            refreshConversations()
            refreshActiveMessages(ifShowing: conversationId)

            var content = Relay_Content_Content()
            content.text.body = text
            content.text.timestamp = timestamp
            if let replyTo {
                content.text.quote.targetTimestamp = replyTo.targetTimestamp
                content.text.quote.author = replyTo.author
                content.text.quote.text = replyTo.text
            }
            content.text.attachments = pointers
            content.groupID = group.id

            // Encrypt once with our sender key, fan the same ciphertext out.
            let sealed = try engine.groupEncrypt(try content.serializedData(), distributionId: distributionId)
            for member in group.members where member != credentials.accountId {
                try await sendEncrypted(sealed, toPeer: member, clientTimestamp: timestamp)
            }
            try storage.messages.updateStatus(messageId: localId, status: .sent)
        } catch {
            log.error("group send failed: \(error)")
            try? storage.messages.updateStatus(messageId: localId, status: .failed)
        }
        refreshActiveMessages(ifShowing: conversationId)
    }

    /// Sends our SKDM (pairwise-encrypted) to any members who don't yet have
    /// it for the group's current distribution id. Tracked in the kv table so
    /// we only distribute once per epoch per member.
    private func distributeSenderKeyIfNeeded(group: StoredGroup) async throws {
        guard let distributionId = UUID(uuidString: group.distributionId) else { return }
        let key = "skdm:\(group.id):\(group.distributionId)"
        var sent = Set(loadStringArray(key))
        let targets = group.members.filter { $0 != credentials.accountId && !sent.contains($0) }
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
                sent.insert(member)
            } catch {
                log.warning("SKDM send to \(member) failed: \(error)")
            }
        }
        saveStringArray(key, Array(sent))
    }

    private func sendGroupUpdate(_ action: Relay_Content_GroupUpdate.Action, group: StoredGroup, target: String) async {
        var content = Relay_Content_Content()
        content.groupUpdate.action = action
        content.groupUpdate.actor = credentials.accountId
        content.groupUpdate.target = target
        content.groupUpdate.name = group.name
        content.groupUpdate.revision = group.revision
        content.groupID = group.id
        guard let data = try? content.serializedData() else { return }
        for member in group.members where member != credentials.accountId {
            try? await sendContent(data, toPeer: member, clientTimestamp: Int64(Date().timeIntervalSince1970 * 1000))
        }
    }

    /// Fans an already-encrypted message (e.g. a sender-key group message) to
    /// every device of `account`, with the same mismatch-retry as 1:1 sends.
    private func sendEncrypted(_ message: SecureMessage, toPeer account: String, clientTimestamp: Int64) async throws {
        guard let socket else { throw RelayWebSocketError.notConnected }
        if knownDevices(ofPeer: account).isEmpty {
            try await refreshSessions(withPeer: account)
        }
        func payloads() -> [DeviceMessagePayload] {
            knownDevices(ofPeer: account).map {
                DeviceMessagePayload(deviceId: $0.id, registrationId: $0.registrationId, message: message)
            }
        }
        var outcome = try await socket.send(to: account, messages: payloads(), clientTimestamp: clientTimestamp)
        if case .mismatchedDevices = outcome {
            try await refreshSessions(withPeer: account)
            outcome = try await socket.send(to: account, messages: payloads(), clientTimestamp: clientTimestamp)
        }
        guard case .ok = outcome else {
            throw RelayAPIError.http(status: 0, message: "group send rejected: \(outcome)")
        }
    }

    /// Re-syncs a group's roster from the relay after a GroupUpdate. If we
    /// were the one removed, the fetch 403s and we simply stop.
    private func handleGroupUpdate(_ info: GroupUpdateInfo) async {
        if info.action == .remove, info.target == credentials.accountId { return }
        do {
            let gs = try await api.fetchGroup(id: info.groupId)
            try storage.messages.upsertGroup(id: gs.id, name: gs.name, distributionId: gs.distributionId, revision: gs.revision, members: gs.members)
            refreshConversations()
            if let convoId = try storage.messages.groupConversationId(groupId: gs.id) {
                refreshActiveMessages(ifShowing: convoId)
            }
            await resolveUsernames(gs.members)
            if let line = systemLine(for: info) {
                insertSystemLine(line, inGroup: info.groupId)
            }
        } catch {
            log.warning("group sync failed for \(info.groupId): \(error)")
        }
    }

    private func systemLine(for info: GroupUpdateInfo) -> String? {
        let actor = displayName(forAccount: info.actor)
        switch info.action {
        case .create: return "\(actor) created the group"
        case .add: return "\(actor) added \(displayName(forAccount: info.target))"
        case .remove: return "\(actor) removed \(displayName(forAccount: info.target))"
        case .leave: return "\(actor) left"
        case .rename: return "\(actor) renamed the group to “\(info.name)”"
        case .unknown: return nil
        }
    }

    private func encryptAttachments(
        _ pending: [PendingAttachment]
    ) async throws -> ([StoredAttachment], [Relay_Content_AttachmentPointer]) {
        var stored: [StoredAttachment] = []
        var pointers: [Relay_Content_AttachmentPointer] = []
        for item in pending {
            let sealed = try AttachmentCipher.seal(item.data)
            let id = try await api.uploadAttachment(sealed.ciphertext)
            try? attachmentStore.write(sealed.ciphertext, for: id)
            stored.append(StoredAttachment(
                id: id, key: sealed.key, digest: sealed.digest, contentType: item.contentType,
                size: Int64(sealed.ciphertext.count), filename: item.filename,
                width: item.width, height: item.height, isDownloaded: true
            ))
            var pointer = Relay_Content_AttachmentPointer()
            pointer.id = id
            pointer.key = sealed.key
            pointer.digest = sealed.digest
            pointer.contentType = item.contentType
            pointer.size = UInt64(sealed.ciphertext.count)
            if let filename = item.filename { pointer.filename = filename }
            pointer.width = UInt32(item.width)
            pointer.height = UInt32(item.height)
            pointers.append(pointer)
        }
        return (stored, pointers)
    }

    private func loadStringArray(_ key: String) -> [String] {
        guard let data = try? storage.database.query(
            "SELECT value FROM kv WHERE key = ?", [.text(key)]
        ).first?.first?.data else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private func saveStringArray(_ key: String, _ value: [String]) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? storage.database.run(
            "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)", [.text(key), .blob(data)]
        )
    }

    // MARK: - Attachments

    /// A picked-but-not-yet-sent attachment (plaintext, held only in memory).
    struct PendingAttachment {
        let data: Data
        let contentType: String
        let filename: String?
        let width: Int
        let height: Int
    }

    /// Downloads and caches an attachment's ciphertext locally (idempotent).
    /// Decryption happens later, in memory, at display time.
    func downloadAttachment(_ attachment: StoredAttachment, in conversationId: String) async {
        if attachmentStore.exists(attachment.id) {
            try? storage.messages.markAttachmentDownloaded(id: attachment.id)
            return
        }
        do {
            let ciphertext = try await api.downloadAttachment(id: attachment.id)
            try attachmentStore.write(ciphertext, for: attachment.id)
            try storage.messages.markAttachmentDownloaded(id: attachment.id)
            refreshActiveMessages(ifShowing: conversationId)
        } catch {
            log.error("attachment download failed: \(error)")
        }
    }

    /// Decrypts a cached attachment to plaintext in memory (never to disk).
    /// Returns nil if it isn't downloaded yet or fails integrity/decryption.
    func attachmentPlaintext(_ attachment: StoredAttachment) -> Data? {
        guard let ciphertext = try? attachmentStore.read(attachment.id) else { return nil }
        return try? AttachmentCipher.open(ciphertext, key: attachment.key, digest: attachment.digest)
    }

    private func sendReceipt(
        _ type: Relay_Content_ReceiptMessage.TypeEnum,
        timestamps: [Int64],
        toPeer account: String
    ) async {
        var content = Relay_Content_Content()
        content.receipt.type = type
        content.receipt.messageTimestamps = timestamps
        do {
            try await sendContent(
                try content.serializedData(),
                toPeer: account,
                clientTimestamp: Int64(Date().timeIntervalSince1970 * 1000)
            )
        } catch {
            log.warning("receipt send failed: \(error)")
        }
    }

    /// Encrypts for every known device of the peer and sends; on a device
    /// mismatch, re-fetches bundles, re-encrypts and retries once.
    private func sendContent(
        _ plaintext: Data,
        toPeer account: String,
        clientTimestamp: Int64,
        ephemeral: Bool = false
    ) async throws {
        guard let socket else { throw RelayWebSocketError.notConnected }
        if knownDevices(ofPeer: account).isEmpty {
            try await refreshSessions(withPeer: account)
        }
        var payloads = try buildPayloads(plaintext, forPeer: account)
        var outcome = try await socket.send(
            to: account, messages: payloads, clientTimestamp: clientTimestamp, ephemeral: ephemeral
        )
        if case .mismatchedDevices = outcome {
            try await refreshSessions(withPeer: account)
            payloads = try buildPayloads(plaintext, forPeer: account)
            outcome = try await socket.send(
                to: account, messages: payloads, clientTimestamp: clientTimestamp, ephemeral: ephemeral
            )
        }
        guard case .ok = outcome else {
            throw RelayAPIError.http(status: 0, message: "send rejected: \(outcome)")
        }
    }

    private func buildPayloads(_ plaintext: Data, forPeer account: String) throws -> [DeviceMessagePayload] {
        try knownDevices(ofPeer: account).map { device in
            let address = try ProtocolAddress(name: account, deviceId: device.id)
            return DeviceMessagePayload(
                deviceId: device.id,
                registrationId: device.registrationId,
                message: try engine.encrypt(plaintext, for: address)
            )
        }
    }

    /// Fetches fresh prekey bundles for the peer and (re)establishes
    /// sessions for every device, recording the device list.
    private func refreshSessions(withPeer account: String) async throws {
        let bundles = try await api.fetchPreKeyBundles(account: account)
        var devices: [PeerDevice] = []
        for bundle in bundles {
            let address = try ProtocolAddress(name: account, deviceId: bundle.deviceId)
            if try !engine.hasSession(with: address) {
                try engine.processPeerBundle(bundle, from: address)
            }
            devices.append(PeerDevice(id: bundle.deviceId, registrationId: bundle.registrationId))
        }
        try storeKnownDevices(devices, ofPeer: account)
    }

    // MARK: - Read state

    func openConversation(_ conversationId: String) {
        activeConversationId = conversationId
        peerTyping = false
        typingResetTask?.cancel()
        refreshActiveMessages(ifShowing: conversationId)
        Task { await markVisibleMessagesRead(in: conversationId) }
        Task {
            if let group = group(for: conversationId) {
                await resolveUsernames(group.members)
            } else if let peer = resolvedPeerAccount(for: conversationId) {
                await resolveUsernames([peer])
            }
        }
    }

    func closeConversation() {
        activeConversationId = nil
        activeMessages = []
        peerTyping = false
        typingResetTask?.cancel()
    }

    private func markVisibleMessagesRead(in conversationId: String) async {
        guard let peer = try? peerAccount(for: conversationId),
              let messages = try? storage.messages.messages(in: conversationId)
        else { return }
        let unread = messages.filter { !$0.isOutgoing && $0.status == .received }
        guard !unread.isEmpty else { return }
        await sendReceipt(.read, timestamps: unread.map(\.timestamp), toPeer: peer)
        for message in unread {
            try? storage.messages.updateStatus(messageId: message.id, status: .read)
        }
    }

    /// Conversations created by an incoming message know only the sender's
    /// account id; resolve the human-readable username from the relay.
    private func backfillUsernameIfNeeded(conversationId: String, account: String) {
        let existing = try? storage.database.query(
            "SELECT peer_username FROM conversations WHERE id = ?", [.text(conversationId)]
        ).first?.first?.string
        guard existing == nil else { return }
        Task {
            guard let username = try? await api.lookupUsername(account: account) else { return }
            _ = try? storage.messages.conversation(withPeer: account, username: username)
            refreshConversations()
        }
    }

    // MARK: - Safety-number verification

    struct PeerVerification {
        let safetyNumber: SafetyNumber
        let state: VerificationState
    }

    /// The safety number and verification state for a conversation's peer,
    /// or nil if no session/identity exists yet (nothing to compare).
    func peerVerification(for conversationId: String) -> PeerVerification? {
        guard let peer = resolvedPeerAccount(for: conversationId) else { return nil }
        do {
            guard let safetyNumber = try engine.safetyNumber(withPeer: peer) else { return nil }
            let state = try storage.signalStore.verificationState(address: peer)
            return PeerVerification(safetyNumber: safetyNumber, state: state)
        } catch {
            log.error("safety number failed: \(error)")
            return nil
        }
    }

    /// Marks the peer verified, or clears verification (also dismissing a
    /// pending safety-number-changed warning).
    func setVerified(_ verified: Bool, conversationId: String) {
        guard let peer = resolvedPeerAccount(for: conversationId) else { return }
        do {
            try storage.signalStore.setVerified(verified, address: peer)
            refreshConversations()
        } catch {
            log.error("setVerified failed: \(error)")
        }
    }

    /// Compares a scannable encoding read from the peer's QR code and, on a
    /// match, marks them verified. Returns whether it matched.
    func verifyScanned(_ encoding: Data, conversationId: String) -> Bool {
        guard let peer = resolvedPeerAccount(for: conversationId) else { return false }
        do {
            let matches = try engine.verifyScannedSafetyNumber(encoding, withPeer: peer)
            if matches {
                try storage.signalStore.setVerified(true, address: peer)
                refreshConversations()
            }
            return matches
        } catch {
            log.error("verifyScanned failed: \(error)")
            return false
        }
    }

    private func resolvedPeerAccount(for conversationId: String) -> String? {
        (try? peerAccount(for: conversationId)).flatMap { $0 }
    }

    // MARK: - Reactions

    /// Applies `emoji` to `message`, or retracts it if the user already
    /// reacted with that same emoji (tap-to-toggle, like Signal). Stores
    /// locally immediately and best-effort delivers to the peer.
    func toggleReaction(_ emoji: String, on message: StoredMessage) {
        let conversationId = message.conversationId
        guard let peer = resolvedPeerAccount(for: conversationId) else { return }
        let targetAuthor = message.isOutgoing ? credentials.accountId : peer
        let remove = message.reactions.first(where: \.isOutgoing)?.emoji == emoji

        do {
            try storage.messages.setReaction(
                conversationId: conversationId,
                targetTimestamp: message.timestamp,
                author: credentials.accountId,
                isOutgoing: true,
                emoji: emoji,
                remove: remove
            )
            refreshActiveMessages(ifShowing: conversationId)
        } catch {
            log.error("store reaction failed: \(error)")
        }

        Task {
            var content = Relay_Content_Content()
            content.reaction.emoji = emoji
            content.reaction.targetAuthor = targetAuthor
            content.reaction.targetTimestamp = message.timestamp
            content.reaction.remove = remove
            content.reaction.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
            do {
                try await sendContent(
                    try content.serializedData(),
                    toPeer: peer,
                    clientTimestamp: content.reaction.timestamp
                )
            } catch {
                log.error("reaction send failed: \(error)")
            }
        }
    }

    // MARK: - Delete

    /// Deletes a message from this device only (no tombstone is sent).
    func deleteMessage(_ messageId: String, in conversationId: String) {
        do {
            reapAttachmentBlobs(messageId: messageId)
            try storage.messages.deleteMessage(id: messageId)
            refreshConversations()
            refreshActiveMessages(ifShowing: conversationId)
        } catch {
            log.error("delete message failed: \(error)")
        }
    }

    /// Removes the on-disk ciphertext for a message's attachments (storage
    /// only tracks metadata; the blob files live in the App Group container).
    private func reapAttachmentBlobs(messageId: String) {
        let ids = (try? storage.database.query(
            "SELECT id FROM attachments WHERE message_id = ?", [.text(messageId)]
        )) ?? []
        for row in ids {
            if let id = row.first?.string { attachmentStore.delete(id) }
        }
    }

    /// How long after sending a message it can still be unsent.
    static let unsendWindow: TimeInterval = 24 * 60 * 60

    /// Whether the local user may unsend (delete-for-everyone) this message:
    /// only their own, still-present messages within the time window.
    func canUnsend(_ message: StoredMessage) -> Bool {
        guard message.isOutgoing, !message.isDeleted else { return false }
        let sentAt = Date(timeIntervalSince1970: Double(message.timestamp) / 1000)
        return Date().timeIntervalSince(sentAt) < Self.unsendWindow
    }

    /// Unsends a message: leaves a local tombstone and tells the peer to do
    /// the same. Delivered like a normal message so it applies even if the
    /// peer is currently offline.
    func unsend(_ message: StoredMessage) {
        let conversationId = message.conversationId
        guard canUnsend(message), let peer = resolvedPeerAccount(for: conversationId) else { return }
        do {
            reapAttachmentBlobs(messageId: message.id)
            try storage.messages.markDeleted(
                conversationId: conversationId,
                targetTimestamp: message.timestamp
            )
            refreshConversations()
            refreshActiveMessages(ifShowing: conversationId)
        } catch {
            log.error("local unsend failed: \(error)")
        }
        Task {
            var content = Relay_Content_Content()
            content.delete.targetTimestamp = message.timestamp
            content.delete.targetAuthor = credentials.accountId
            do {
                try await sendContent(
                    try content.serializedData(),
                    toPeer: peer,
                    clientTimestamp: Int64(Date().timeIntervalSince1970 * 1000)
                )
            } catch {
                log.error("unsend send failed: \(error)")
            }
        }
    }

    // MARK: - Typing indicators (ephemeral)

    func sendTyping(_ action: Relay_Content_TypingMessage.Action, in conversationId: String) {
        guard let peer = resolvedPeerAccount(for: conversationId) else { return }
        Task {
            var content = Relay_Content_Content()
            content.typing.action = action
            content.typing.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
            do {
                try await sendContent(
                    try content.serializedData(),
                    toPeer: peer,
                    clientTimestamp: content.typing.timestamp,
                    ephemeral: true
                )
            } catch {
                log.debug("typing send skipped: \(error)")
            }
        }
    }

    private func applyPeerTyping(started: Bool, peerAccount: String?) {
        guard let peerAccount,
              let conversationId = existingConversation(withPeer: peerAccount),
              conversationId == activeConversationId else { return }
        typingResetTask?.cancel()
        guard started else {
            peerTyping = false
            return
        }
        peerTyping = true
        // Self-heal if the "stopped" frame is lost (ephemeral, never queued).
        typingResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.peerTyping = false
        }
    }

    private func clearPeerTyping(for conversationId: String) {
        guard conversationId == activeConversationId else { return }
        typingResetTask?.cancel()
        peerTyping = false
    }

    private func existingConversation(withPeer account: String) -> String? {
        try? storage.database.query(
            "SELECT id FROM conversations WHERE peer_account = ?", [.text(account)]
        ).first?.first?.string
    }

    // MARK: - Peer device bookkeeping (encrypted kv table)

    private struct PeerDevice: Codable {
        let id: UInt32
        let registrationId: UInt32
    }

    private func knownDevices(ofPeer account: String) -> [PeerDevice] {
        guard let data = try? storage.database.query(
            "SELECT value FROM kv WHERE key = ?", [.text("peer-devices:\(account)")]
        ).first?.first?.data else { return [] }
        return (try? JSONDecoder().decode([PeerDevice].self, from: data)) ?? []
    }

    private func storeKnownDevices(_ devices: [PeerDevice], ofPeer account: String) throws {
        try storage.database.run(
            "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
            [.text("peer-devices:\(account)"), .blob(try JSONEncoder().encode(devices))]
        )
    }

    // MARK: - View state refresh

    private func peerAccount(for conversationId: String) throws -> String? {
        try storage.database.query(
            "SELECT peer_account FROM conversations WHERE id = ?", [.text(conversationId)]
        ).first?.first?.string
    }

    private func refreshConversations() {
        conversations = (try? storage.messages.conversations()) ?? []
    }

    private func refreshActiveMessages(ifShowing conversationId: String) {
        guard activeConversationId == conversationId else { return }
        activeMessages = (try? storage.messages.messages(in: conversationId)) ?? []
    }
}

/// Never-reused prekey ids, persisted in the encrypted kv table.
nonisolated final class KVPreKeyIdAllocator: PreKeyIdAllocating, @unchecked Sendable {
    private let database: Database

    init(database: Database) {
        self.database = database
    }

    func allocateIds(count: Int) throws -> Range<UInt32> {
        try database.transaction {
            let current = try database.query(
                "SELECT value FROM kv WHERE key = 'next-prekey-id'"
            ).first?.first?.data.flatMap { UInt32(String(decoding: $0, as: UTF8.self)) } ?? 1
            let next = current + UInt32(count)
            try database.run(
                "INSERT OR REPLACE INTO kv (key, value) VALUES ('next-prekey-id', ?)",
                [.blob(Data("\(next)".utf8))]
            )
            return current..<next
        }
    }
}
