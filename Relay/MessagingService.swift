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
import RelayKit
import SwiftProtobuf
import SecureStorage
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
    private let api: RelayAPIClient
    private let maintainer = PreKeyMaintainer()
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
        self.api = RelayAPIClient(baseURL: serverURL, credentials: credentials, session: session)
        self.allocator = KVPreKeyIdAllocator(database: storage.database)
        refreshConversations()
    }

    // MARK: - Lifecycle

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
        Task { await socket?.disconnect() }
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
            // Exactly-once: skip if the NSE (or an earlier delivery) already
            // processed this envelope. Decryption is destructive, so we must
            // not run it twice.
            guard try storage.messages.claimEnvelope(id: envelope.id) else { return }
            let sender = try ProtocolAddress(
                name: envelope.senderAccount,
                deviceId: envelope.senderDevice
            )
            let plaintext = try engine.decrypt(envelope.message, from: sender)
            let content = try Relay_Content_Content(serializedBytes: plaintext)

            switch content.body {
            case .text(let text):
                let conversationId = try storage.messages.conversation(withPeer: envelope.senderAccount)
                backfillUsernameIfNeeded(conversationId: conversationId, account: envelope.senderAccount)
                let quote: QuotedMessage? = text.hasQuote
                    ? QuotedMessage(
                        targetTimestamp: text.quote.targetTimestamp,
                        author: text.quote.author,
                        text: text.quote.text
                    )
                    : nil
                let inserted = try storage.messages.insertMessage(
                    id: envelope.id,
                    conversationId: conversationId,
                    isOutgoing: false,
                    body: text.body,
                    timestamp: text.timestamp,
                    status: .received,
                    replyTo: quote
                )
                if inserted {
                    await sendReceipt(.delivery, timestamps: [text.timestamp], toPeer: envelope.senderAccount)
                }
                clearPeerTyping(for: conversationId) // a real message ends typing
                refreshConversations()
                refreshActiveMessages(ifShowing: conversationId)
            case .reaction(let reaction):
                let conversationId = try storage.messages.conversation(withPeer: envelope.senderAccount)
                try storage.messages.setReaction(
                    conversationId: conversationId,
                    targetTimestamp: reaction.targetTimestamp,
                    author: envelope.senderAccount,
                    isOutgoing: false,
                    emoji: reaction.emoji,
                    remove: reaction.remove
                )
                refreshActiveMessages(ifShowing: conversationId)
            case .receipt(let receipt):
                let conversationId = try storage.messages.conversation(withPeer: envelope.senderAccount)
                try storage.messages.applyReceipt(
                    conversationId: conversationId,
                    timestamps: receipt.messageTimestamps,
                    status: receipt.type == .read ? .read : .delivered
                )
                refreshActiveMessages(ifShowing: conversationId)
            case .delete(let deletion):
                let conversationId = try storage.messages.conversation(withPeer: envelope.senderAccount)
                try storage.messages.markDeleted(
                    conversationId: conversationId,
                    targetTimestamp: deletion.targetTimestamp
                )
                refreshConversations()
                refreshActiveMessages(ifShowing: conversationId)
            case .typing(let typing):
                handleIncomingTyping(typing, fromPeer: envelope.senderAccount)
            case .none:
                break
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

    func sendMessage(_ text: String, in conversationId: String, replyTo: QuotedMessage? = nil) async {
        guard let peer = try? peerAccount(for: conversationId) else { return }
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let localId = UUID().uuidString
        do {
            try storage.messages.insertMessage(
                id: localId,
                conversationId: conversationId,
                isOutgoing: true,
                body: text,
                timestamp: timestamp,
                status: .sending,
                replyTo: replyTo
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
            try await sendContent(try content.serializedData(), toPeer: peer, clientTimestamp: timestamp)
            try storage.messages.updateStatus(messageId: localId, status: .sent)
        } catch {
            log.error("send failed: \(error)")
            try? storage.messages.updateStatus(messageId: localId, status: .failed)
        }
        refreshActiveMessages(ifShowing: conversationId)
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

    private func handleIncomingTyping(_ typing: Relay_Content_TypingMessage, fromPeer account: String) {
        guard let conversationId = existingConversation(withPeer: account),
              conversationId == activeConversationId else { return }
        typingResetTask?.cancel()
        guard typing.action == .started else {
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
