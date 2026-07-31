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
            try storage.messages.deleteMessage(id: messageId)
            refreshConversations()
            refreshActiveMessages(ifShowing: conversationId)
        } catch {
            log.error("delete message failed: \(error)")
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
