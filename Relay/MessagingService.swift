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

enum MessagingError: LocalizedError {
    case attachmentTooLarge

    var errorDescription: String? {
        switch self {
        case .attachmentTooLarge: return "Attachment exceeds the 25 MB size limit."
        }
    }
}

@Observable
final class MessagingService {
    enum ConnectionState: Equatable {
        case disconnected, connecting, connected
    }

    private static func isEphemeralCallSignal(_ type: Relay_Content_CallMessage.TypeEnum) -> Bool {
        switch type {
        case .answer, .ice, .busy, .ringing, .groupJoin, .groupLeave:
            return true
        case .offer, .hangup, .groupRing, .UNRECOGNIZED:
            return false
        }
    }

    let credentials: RelayCredentials
    let serverURL: URL
    /// Our own username; nil for accounts saved before it was recorded.
    var username: String?
    /// Shared, certificate-pinned session for REST and the WebSocket.
    private let session: URLSession

    private(set) var conversations: [Conversation] = []
    private(set) var callHistory: [StoredCall] = []
    private(set) var activeMessages: [StoredMessage] = []
    private(set) var activeConversationId: String?
    /// Set to the conversation ID whose messages have just finished loading.
    /// Lets ChatView distinguish "still loading" from "genuinely empty".
    private(set) var messagesLoadedConversationId: String? = nil
    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var authenticationExpired = false
    /// Conversation IDs where the peer is currently typing. Tracked per-conversation
    /// so the list view can show "typing…" even when that chat isn't open.
    private(set) var typingConversations: Set<String> = []
    /// Mute expiry per conversation: Int64.max = forever, positive = Unix ms expiry.
    private var muteExpiries: [String: Int64] = [:]
    /// Receives incoming call signalling events for routing to CallManager.
    var onCallMessage: ((CallInfo) async -> Void)?
    /// Called when a verified nuke command is received. The closure must wipe local storage.
    var onNukeReceived: (() async -> Void)?

    private let storage: SecureStore
    private let keychain: KeychainSecureStore
    private let engine: CryptoEngine
    private let processor: EnvelopeProcessor
    private let api: RelayAPIClient
    private let maintainer = PreKeyMaintainer()
    private let attachmentStore = AttachmentBlobStore(appGroupId: AppModel.appGroupId)
    private let allocator: KVPreKeyIdAllocator
    private var socket: RelayWebSocket?
    private var connectionTask: Task<Void, Never>?
    private var expireTask: Task<Void, Never>?
    private var typingResetTasks: [String: Task<Void, Never>] = [:]
    private let log = Logger(subsystem: "com.relaytextingapp.Relay", category: "messaging")

    // In-memory caches: avoids DB queries during SwiftUI render passes.
    private var nameCache: [String: String] = [:]
    private var avatarCache: [String: Data?] = [:]
    private var cachedActiveGroup: StoredGroup?? = nil  // nil = uncached; .some(nil) = confirmed 1:1
    // Deduplication: collapse rapid-fire refresh calls to a single deferred update.
    private var conversationsRefreshScheduled = false
    private var conversationsRefreshVersion: Int = 0
    // Suppress per-envelope refreshes while draining the server queue on connect.
    // Starts false so the init-time refreshConversations() populates App Group storage.
    private var isDrainingQueue = false
    /// Account IDs the local user has blocked. Persisted in the encrypted kv table.
    private(set) var blockedAccounts: Set<String> = []
    /// Presence snapshots keyed by account id; populated whenever we poll the
    /// active conversation's peer and used to show online dots in the list.
    private(set) var presenceCache: [String: Presence] = [:]
    /// Conversation that tried to send to a replacement identity key before
    /// the user acknowledged the new safety number.
    private(set) var blockedSafetyWarningConversationId: String?
    /// Tracks whether the current network path uses Wi-Fi (vs cellular).
    private var pathMonitor: NWPathMonitor?
    private(set) var isOnWifi: Bool = true

    // MARK: Sealed sender
    /// This device's cached sealed-sender delivery certificate and its expiry
    /// (ms). Refreshed a day before it lapses.
    private var cachedSenderCert: (data: Data, expiresAt: Int64)?
    /// Per-account sealed-sender access keys, captured when we fetch prekey
    /// bundles. Needed to address a recipient on the unauthenticated path.
    private var peerAccessKeys: [String: Data] = [:]

    init(credentials: RelayCredentials, serverURL: URL, username: String?, storage: SecureStore, keychain: KeychainSecureStore, session: URLSession) throws {
        self.credentials = credentials
        self.serverURL = serverURL
        self.username = username
        self.storage = storage
        self.keychain = keychain
        self.session = session
        self.engine = try storage.makeCryptoEngine(
            accountId: credentials.accountId,
            deviceId: credentials.deviceId
        )
        self.processor = EnvelopeProcessor(
            storage: storage,
            engine: engine,
            ownAccountId: credentials.accountId,
            sealedSenderTrustRoot: RelayConfig.sealedSenderTrustRoot
        )
        self.api = RelayAPIClient(baseURL: serverURL, credentials: credentials, session: session)
        self.allocator = KVPreKeyIdAllocator(database: storage.database)
        loadMuteExpiries()
        loadBlockedAccounts()
        refreshConversations()
        refreshCallHistory()
    }

    // MARK: - Lifecycle

    private struct PendingCallOffer: Codable {
        let callId: String
        let callerAccount: String
        let sdp: String
    }

    private static let pendingCallOfferPrefix = "pending-call-offer:"

    /// Exposes the REST client so PushKitDelegate can register the VoIP token.
    var apiClient: RelayAPIClient { api }

    /// Redeems a one-time contact invite token, returning the inviter's username
    /// so the caller can open a conversation. Throws if the token is spent/expired.
    func claimContactInvite(token: String) async throws -> String {
        let (_, username) = try await api.claimContactInvite(token: token)
        return username
    }

    /// Mints a one-time contact invite token and returns a shareable https link.
    func createContactInviteLink() async throws -> URL {
        let (token, _) = try await api.createContactInvite()
        guard let url = URL(string: "https://relaymsg.app/c/\(token)") else {
            throw RelayAPIError.malformedResponse
        }
        return url
    }

    /// Registers this device's APNs token with the relay so it can wake us
    /// for offline messages. Best-effort — messaging works without it.
    func uploadPushToken(_ token: String) async {
        do {
            try await api.setAPNSToken(token)
        } catch {
            log.warning("apns token upload failed: \(PrivacyRedactor.error(error))")
        }
    }

    /// Uploads the first key publication after registration.
    func publishInitialKeys() async throws {
        try await maintainer.publishInitialKeys(api: api, engine: engine, allocator: allocator)
    }

    /// Sends a call signalling message over the E2EE channel.
    /// OFFER and HANGUP must survive offline delivery; ANSWER/ICE/BUSY/RINGING
    /// are live control traffic and must not generate normal APNs alerts.
    @discardableResult
    func sendCallMessage(_ msg: Relay_Content_CallMessage, to account: String) async -> Bool {
        var content = Relay_Content_Content()
        content.call = msg
        do {
            try await waitForSocketIfNeeded()
            try await sendContent(
                try content.serializedData(),
                toPeer: account,
                clientTimestamp: Int64(Date().timeIntervalSince1970 * 1000),
                ephemeral: Self.isEphemeralCallSignal(msg.type)
            )
            log.info("call signal sent type=\(String(describing: msg.type))")
            return true
        } catch {
            log.warning("call message send failed type=\(String(describing: msg.type)): \(PrivacyRedactor.error(error))")
            return false
        }
    }

    /// Fans a group call signal out to every account concurrently.
    func sendGroupCallMessage(_ msg: Relay_Content_CallMessage, toAccounts accounts: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { _ = await self.sendCallMessage(msg, to: account) }
            }
        }
    }

    /// Triggers VoIP push notifications for multiple participants of a group call.
    func triggerGroupCallPushes(accounts: [String], callId: String, callerName: String, kind: CallKind) async {
        for account in accounts {
            await triggerCallPush(account: account, callId: callId, callerName: callerName, kind: kind)
        }
    }

    /// Triggers a server-side VoIP push to wake the callee's device.
    func triggerCallPush(account: String, callId: String, callerName: String, kind: CallKind) async {
        do {
            try await api.triggerCallPush(
                account: account,
                callID: callId,
                callerName: callerName,
                callerAccount: credentials.accountId,
                kind: kind.rawValue
            )
        } catch {
            log.warning("call push trigger failed: \(PrivacyRedactor.error(error))")
        }
    }

    private func waitForSocketIfNeeded() async throws {
        var attempts = 0
        while socket == nil && attempts < 20 {
            try await Task.sleep(for: .milliseconds(250))
            attempts += 1
        }
        if socket == nil { throw RelayWebSocketError.notConnected }
    }

    /// Replays call offers decrypted by the Notification Service Extension while
    /// the app was locked. The NSE must decrypt those envelopes to suppress the
    /// generic APNs banner; this hands the SDP back to CallManager so answering
    /// from CallKit can still generate and send ANSWER.
    func replayPendingCallOffers() async {
        let rows = (try? storage.database.query(
            "SELECT key, value FROM kv WHERE key LIKE ?",
            [.text(Self.pendingCallOfferPrefix + "%")]
        )) ?? []

        for row in rows {
            guard let key = row.first?.string,
                  let data = row.dropFirst().first?.data,
                  let offer = try? JSONDecoder().decode(PendingCallOffer.self, from: data)
            else { continue }

            await onCallMessage?(CallInfo(
                callId: offer.callId,
                type: .offer,
                sdp: offer.sdp,
                ice: "",
                callerAccount: offer.callerAccount
            ))
            try? storage.database.run("DELETE FROM kv WHERE key = ?", [.text(key)])
        }
    }

    func start() {
        guard connectionTask == nil else { return }
        connectionTask = Task { await runConnectionLoop() }
        startPathMonitor()
        expireTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await MainActor.run {
                    _ = try? self?.storage.messages.deleteExpiredMessages()
                    self?.refreshConversations()
                }
                await self?.flushDueScheduledMessages()
            }
        }
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor [weak self] in self?.isOnWifi = wifi }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        pathMonitor = monitor
    }

    func stop() {
        connectionTask?.cancel()
        connectionTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        expireTask?.cancel()
        expireTask = nil
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
            isDrainingQueue = true
            do {
                _ = try await api.listDevices()
                authenticationExpired = false
            } catch RelayAPIError.http(let status, _) where status == 401 {
                log.warning("relay credentials expired; stopping reconnect loop")
                authenticationExpired = true
                isDrainingQueue = false
                connectionState = .disconnected
                connectionTask = nil
                return
            } catch {
                log.warning("relay auth/connectivity preflight failed: \(PrivacyRedactor.localizedError(error))")
            }
            let socket = RelayWebSocket(baseURL: serverURL, credentials: credentials, session: session)
            self.socket = socket
            for await event in await socket.connect() {
                switch event {
                case .queueDrained:
                    isDrainingQueue = false
                    connectionState = .connected
                    backoffSeconds = 1.0
                    // One batch refresh after draining all queued messages.
                    refreshConversations()
                    do {
                        try await maintainer.replenishIfNeeded(api: api, engine: engine, allocator: allocator)
                    } catch {
                        log.warning("prekey replenishment failed: \(PrivacyRedactor.error(error))")
                    }
                    await rotateMailboxIfNeeded()
                    await ensureNoteToSelf()
                case .envelope(let envelope):
                    await handleEnvelope(envelope)
                case .nukeCommand(let nuke):
                    await handleNukeEvent(nuke)
                case .deviceListChanged:
                    // Refresh device list so fan-out stays in sync.
                    Task { try? await self.refreshDeviceList() }
                case .disconnected:
                    isDrainingQueue = false
                    break
                }
            }
            self.socket = nil
            isDrainingQueue = false
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
        // Drop messages from blocked accounts (still ACK so the server removes them).
        guard !isBlocked(envelope.senderAccount) else { return }
        do {
            // Run crypto + DB write off the main thread. Serialization is
            // maintained by the caller: the connection loop awaits each call
            // before delivering the next envelope, so ratchet state advances
            // one message at a time even though the work runs on a bg thread.
            let proc = processor
            let blocked = blockedAccounts
            let result = try await Task.detached(priority: .userInitiated) {
                try proc.process(envelope, blockedAccounts: blocked)
            }.value

            if let timestamp = result.sideEffects.deliveryReceiptTimestamp {
                let groupId = result.conversationId.flatMap { group(for: $0)?.id }
                await sendReceipt(.delivery, timestamps: [timestamp], toPeer: envelope.senderAccount, groupId: groupId)
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
                // Fire a local notification for @mentions in muted conversations
                // so the user still sees they were called out.
                if let body = result.notification?.body,
                   let me = username,
                   body.localizedCaseInsensitiveContains("@\(me)"),
                   isConversationMuted(conversationId),
                   activeConversationId != conversationId
                {
                    postMentionNotification(body: body, senderAccount: result.peerAccount ?? "")
                }
            }
            if let conversationId = result.conversationId {
                refreshConversations()
                refreshActiveMessages(ifShowing: conversationId)
                // If this conversation is currently open, mark the new message read immediately
                // so the sender sees "read" without the recipient having to exit and re-enter.
                if activeConversationId == conversationId {
                    Task { await markVisibleMessagesRead(in: conversationId) }
                }
                // Intercept special-prefix messages for notepad and location.
                if let lastMsg = activeMessages.last, result.outcome == .stored {
                    let body = lastMsg.body
                    if body.hasPrefix(notepadPrefix) {
                        let content = String(body.dropFirst(notepadPrefix.count))
                        setNotepadContent(content, for: conversationId)
                    } else if let payload = LocationPayload.decode(body) {
                        LocationShareManager.shared.handleIncoming(
                            payload: payload, fromConversation: conversationId)
                    }
                }
            }
            if result.pollVoteInfo != nil, let conversationId = result.conversationId {
                refreshActiveMessages(ifShowing: conversationId)
            }
            if let groupUpdate = result.groupUpdate {
                await handleGroupUpdate(groupUpdate)
            }
            if let profile = result.profile {
                await applyPeerProfile(profile)
            }
            if let callInfo = result.callInfo {
                await onCallMessage?(callInfo)
            }
        } catch {
            log.error("failed to process encrypted envelope: \(PrivacyRedactor.error(error))")
        }
    }

    // MARK: - Blinded discovery

    /// Resolves a username to its account id without revealing the username to the
    /// relay: blind → server OPRF eval → unblind → token → resolve. Throws
    /// `RelayAPIError.http(404,…)` when no such user exists.
    func resolveAccount(username: String) async throws -> String {
        guard let blinded = BlindedDiscovery.blind(username) else {
            throw RelayAPIError.malformedResponse
        }
        let evaluated = try await api.directoryEvaluate(blinded: [blinded.element])
        guard let ev = evaluated.first,
              let token = BlindedDiscovery.token(for: blinded, evaluated: ev) else {
            throw RelayAPIError.malformedResponse
        }
        guard let match = try await api.directoryResolve(tokens: [token]).first else {
            throw RelayAPIError.http(status: 404, message: "no such user")
        }
        return match.accountId
    }

    /// Privately matches a batch of address-book emails against the directory.
    /// The relay learns which registered users you know but never sees the
    /// plaintext of any email (registered or not). Returns one entry per match.
    func discoverContacts(emails: [String]) async throws -> [(email: String, accountId: String, username: String)] {
        let unique = Array(Set(emails))
        var blindeds: [BlindedDiscovery.Blinded] = []
        var emailForBlind: [String] = []
        for email in unique {
            guard let b = BlindedDiscovery.blind(email) else { continue }
            blindeds.append(b)
            emailForBlind.append(email)
        }
        guard !blindeds.isEmpty else { return [] }

        var results: [(email: String, accountId: String, username: String)] = []
        let chunkSize = 1024 // server batch cap
        var start = 0
        while start < blindeds.count {
            let end = min(start + chunkSize, blindeds.count)
            let chunkBlinds = Array(blindeds[start..<end])
            let chunkEmails = Array(emailForBlind[start..<end])
            let evaluated = try await api.directoryEvaluate(blinded: chunkBlinds.map { $0.element })
            guard evaluated.count == chunkBlinds.count else { throw RelayAPIError.malformedResponse }
            var tokenToEmail: [Data: String] = [:]
            var tokens: [Data] = []
            for (i, b) in chunkBlinds.enumerated() {
                guard let token = BlindedDiscovery.token(for: b, evaluated: evaluated[i]) else { continue }
                tokenToEmail[token] = chunkEmails[i]
                tokens.append(token)
            }
            for m in try await api.directoryResolve(tokens: tokens) {
                if let email = tokenToEmail[m.token] {
                    results.append((email: email, accountId: m.accountId, username: m.username))
                }
            }
            start = end
        }
        return results
    }

    // MARK: - Sending

    /// Starts (or reopens) a conversation with a username; resolves it to
    /// an account id via blinded discovery.
    func startConversation(username: String) async throws -> String {
        let account = try await resolveAccount(username: username)
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
            // Announce-only: only admins may send.
            if group.isAnnounceOnly && !group.admins.contains(credentials.accountId) { return }
            await sendGroupMessage(text, in: conversationId, group: group, replyTo: replyTo, attachments: pending)
            return
        }
        guard let peer = try? peerAccount(for: conversationId) else { return }

        // Blocked peer: silently drop.
        if isBlocked(peer) { return }

        // Note to Self: Signal can't establish a session with its own address
        // (sender == receiver breaks the Double Ratchet). Store locally instead —
        // attachments are sealed and kept on-device only.
        if peer == noteToSelfAccount {
            let ts = Int64(Date().timeIntervalSince1970 * 1000)
            var localAttachments: [StoredAttachment] = []
            for item in pending {
                guard let sealed = try? AttachmentCipher.seal(item.data) else { continue }
                let attachId = UUID().uuidString
                try? attachmentStore.write(sealed.ciphertext, for: attachId)
                localAttachments.append(StoredAttachment(
                    id: attachId, key: sealed.key, digest: sealed.digest,
                    contentType: item.contentType, size: Int64(sealed.ciphertext.count),
                    filename: item.filename, width: item.width, height: item.height,
                    isDownloaded: true
                ))
            }
            _ = try? storage.messages.insertMessage(
                id: UUID().uuidString, conversationId: conversationId,
                isOutgoing: true, body: text, timestamp: ts, status: .read,
                replyTo: replyTo, attachments: localAttachments
            )
            refreshConversations()
            refreshActiveMessages(ifShowing: conversationId)
            return
        }

        // Ensure profile is current before sending (no-op if already up to date).
        Task { await sendMyProfileIfNeeded(toPeer: peer) }

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
            content.senderAccountID = credentials.accountId
            content.senderDeviceID = credentials.deviceId
            let disappearSecs = conversations.first(where: { $0.id == conversationId })?.disappearingSeconds ?? 0
            if disappearSecs > 0 { content.expiresAfterMs = disappearSecs * 1000 }
            // Opt-in cover-traffic delay: the message already shows locally as
            // "sending"; hold the wire transmission for a short random interval.
            await applySendJitter()
            try await sendContent(try content.serializedData(), toPeer: peer, clientTimestamp: timestamp)
            try storage.messages.updateStatus(messageId: localId, status: .sent)
            donateInteraction(peerAccount: peer, conversationId: conversationId)
            // Send a sync copy to own other devices so they show this as sent.
            await sendSyncToOwnDevices(content: content, peer: peer, timestamp: timestamp)
        } catch {
            log.error("send failed: \(PrivacyRedactor.error(error))")
            try? storage.messages.updateStatus(messageId: localId, status: .failed)
            if let safetyError = error as? SafetyNumberChangedError {
                noteBlockedSafetyWarning(peer: safetyError.peer)
            }
        }
        refreshActiveMessages(ifShowing: conversationId)
    }

    /// Sends a copy of the given content to own other devices so they can store
    /// the outgoing message. Bypasses sendContent to exclude our own device and
    /// skip the identity acknowledgement check (own devices are implicitly trusted).
    /// Errors are swallowed — sync is best-effort.
    private func sendSyncToOwnDevices(
        content: Relay_Content_Content,
        peer: String,
        timestamp: Int64
    ) async {
        var sync = content
        sync.syncRecipient = peer
        guard let data = try? sync.serializedData(),
              let padded = try? ContentPadding.pad(data) else { return }

        // Resolve own other devices, always fetching fresh to catch newly linked devices.
        var devices: [PeerDevice]
        do {
            try await refreshSessions(withPeer: credentials.accountId)
            let allOwn = try await knownMailboxDevices(ofPeer: credentials.accountId)
            // Exclude this device — we already have the message stored locally.
            devices = allOwn.filter { $0.id != credentials.deviceId }
        } catch { return }
        guard !devices.isEmpty else { return }

        guard let payloads = try? buildMailboxPayloads(padded, forPeer: credentials.accountId, devices: devices) else { return }
        _ = try? await sendMailboxPayloads(payloads, clientTimestamp: timestamp)
    }

    // MARK: - Groups

    /// Sentinel sender for locally-inserted group system lines.
    static let systemSender = "__system__"
    /// The peer account for "Note to Self" is the user's own account — messages
    /// are sent to yourself via the server so they go through the normal E2EE path.
    var noteToSelfAccount: String { credentials.accountId }

    /// The stored group backing a conversation (nil for 1:1), for the UI.
    func group(for conversationId: String) -> StoredGroup? {
        try? groupForConversation(conversationId)
    }

    /// A human name for an account, in precedence order: "You" for self, a
    /// user-set nickname, the known username, else a short account prefix.
    /// Result is cached in memory to avoid DB reads during render.
    func displayName(forAccount account: String) -> String {
        if account == credentials.accountId { return "You" }
        if let cached = nameCache[account] { return cached }
        let name = resolveDisplayName(forAccount: account)
        if nameCache.count >= 500 { nameCache.removeAll() }
        nameCache[account] = name
        return name
    }

    private func resolveDisplayName(forAccount account: String) -> String {
        if let nick = nickname(forAccount: account) { return nick }
        if let stored = (try? storage.messages.peerProfile(account: account)) ?? nil,
           let name = stored.displayName, !name.isEmpty { return name }
        if let name = username(forAccount: account) { return name }
        return String(account.prefix(8))
    }

    /// The known username for an account (no nickname or prefix fallback),
    /// for showing the underlying handle on a contact card.
    func username(forAccount account: String) -> String? {
        if let cached = cachedUsername(account) { return cached }
        return (try? storage.database.query(
            "SELECT peer_username FROM conversations WHERE peer_account = ?", [.text(account)]
        ).first?.first?.string) ?? nil
    }

    /// A user-set display-name override for a peer, if any. Stored in the kv
    /// table (like the username cache) keyed by account id.
    func nickname(forAccount account: String) -> String? {
        (try? storage.database.query(
            "SELECT value FROM kv WHERE key = ?", [.text("nick:\(account)")]
        ).first?.first?.data).flatMap { $0 }.flatMap { String(bytes: $0, encoding: .utf8) }
    }

    /// Sets (or clears, when empty) a peer's display-name override and
    /// refreshes any views showing the name.
    func setNickname(_ name: String?, forAccount account: String) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            try? storage.database.run(
                "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
                [.text("nick:\(account)"), .blob(Data(trimmed.utf8))]
            )
        } else {
            try? storage.database.run("DELETE FROM kv WHERE key = ?", [.text("nick:\(account)")])
        }
        nameCache[account] = nil  // force re-resolve on next access
        refreshConversations()
        if let id = activeConversationId { refreshActiveMessages(ifShowing: id) }
    }

    // MARK: - Own profile

    /// This user's self-set display name (shown to peers once profile
    /// distribution lands). Stored locally in kv.
    var myDisplayName: String? {
        (try? storage.database.query(
            "SELECT value FROM kv WHERE key = 'me:name'"
        ).first?.first?.data).flatMap { $0 }.flatMap { String(bytes: $0, encoding: .utf8) }
    }

    func setMyDisplayName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != myDisplayName else { return }
        try? storage.database.run(
            "INSERT OR REPLACE INTO kv (key, value) VALUES ('me:name', ?)",
            [.blob(Data(trimmed.utf8))]
        )
        bumpMyProfileRevision()
    }

    /// This user's profile photo as image bytes (already downscaled by the
    /// caller). Nil if unset. Stored locally in kv.
    var myAvatarData: Data? {
        (try? storage.database.query(
            "SELECT value FROM kv WHERE key = 'me:avatar'"
        ).first?.first?.data).flatMap { $0 }
    }

    func setMyAvatarData(_ data: Data?) {
        if let data {
            try? storage.database.run(
                "INSERT OR REPLACE INTO kv (key, value) VALUES ('me:avatar', ?)",
                [.blob(data)]
            )
        } else {
            try? storage.database.run("DELETE FROM kv WHERE key = 'me:avatar'")
        }
        bumpMyProfileRevision()
    }

    // MARK: - Profile distribution (E2EE)

    /// My profile "clock", bumped whenever the name/avatar changes. A peer
    /// keeps the newest by revision; a bump also re-arms sending to every peer.
    private var myProfileRevision: Int64 {
        readKVInt("me:rev")
    }

    private func bumpMyProfileRevision() {
        writeKVInt("me:rev", Int64(Date().timeIntervalSince1970 * 1000))
        // Invalidate the cached avatar upload; it belongs to the old revision.
        try? storage.database.run("DELETE FROM kv WHERE key IN ('me:aptr', 'me:aptrrev')")
        distributeProfileUpdate()
    }

    /// Push the updated profile to every known peer (DM + group members) after a
    /// name/avatar change so others see it without needing to reopen the conversation.
    private func distributeProfileUpdate() {
        // DM peers
        let dmPeers = conversations
            .filter { !$0.isGroup }
            .compactMap { $0.peerAccount.isEmpty ? nil : $0.peerAccount }
        // Group members (flatten, deduplicate, exclude self)
        let groupMembers: [String] = conversations
            .filter { $0.isGroup }
            .compactMap { try? storage.messages.group(id: $0.id) }
            .flatMap { $0.members }
            .filter { $0 != credentials.accountId }
        let allPeers = Array(Set(dmPeers + groupMembers))
        guard !allPeers.isEmpty else { return }
        Task {
            for peer in allPeers {
                await sendMyProfileIfNeeded(toPeer: peer)
            }
        }
    }

    /// Sends my current profile to a peer over the pairwise session if they
    /// haven't already received this revision. Called when opening a chat.
    private func sendMyProfileIfNeeded(toPeer account: String) async {
        let rev = myProfileRevision
        guard rev > 0 else { return } // nothing set yet
        guard readKVInt("pfsent:\(account)") < rev else { return }
        do {
            var content = Relay_Content_Content()
            content.profile.displayName = myDisplayName ?? ""
            content.profile.timestamp = rev
            if let pointer = try await currentAvatarPointer() {
                content.profile.avatar = pointer
            }
            try await sendContent(try content.serializedData(), toPeer: account, clientTimestamp: rev)
            writeKVInt("pfsent:\(account)", rev)
        } catch {
            log.error("profile send failed: \(PrivacyRedactor.error(error))")
        }
    }

    /// Seals + uploads my avatar once per revision, caching the resulting
    /// pointer so it isn't re-uploaded for every peer.
    private func currentAvatarPointer() async throws -> Relay_Content_AttachmentPointer? {
        guard let data = myAvatarData else { return nil }
        let rev = myProfileRevision
        if readKVInt("me:aptrrev") == rev,
           let cached = ((try? storage.database.query(
               "SELECT value FROM kv WHERE key = 'me:aptr'").first?.first?.data) ?? nil),
           let pointer = try? Relay_Content_AttachmentPointer(serializedBytes: cached) {
            return pointer
        }
        let sealed = try AttachmentCipher.seal(data)
        let id = try await api.uploadAttachment(sealed.ciphertext)
        var pointer = Relay_Content_AttachmentPointer()
        pointer.id = id
        pointer.key = sealed.key
        pointer.digest = sealed.digest
        pointer.contentType = "image/jpeg"
        pointer.size = UInt64(sealed.ciphertext.count)
        if let encoded = try? pointer.serializedData() {
            try? storage.database.run(
                "INSERT OR REPLACE INTO kv (key, value) VALUES ('me:aptr', ?)", [.blob(encoded)])
            writeKVInt("me:aptrrev", rev)
        }
        return pointer
    }

    /// Stores a peer's incoming profile (newest-wins), downloading + decrypting
    /// a changed avatar via the blob pipeline. No-op if we already have a
    /// newer revision.
    private func applyPeerProfile(_ profile: ProfileInfo) async {
        let existing = (try? storage.messages.peerProfile(account: profile.account)) ?? nil
        if let existing, existing.revision >= profile.revision { return }

        var avatarData = existing?.avatarData
        var avatarId = existing?.avatarId
        var avatarReady = true
        if let avatar = profile.avatar {
            if avatar.id != existing?.avatarId {
                if let ciphertext = try? await api.downloadAttachment(id: avatar.id),
                   let plaintext = try? AttachmentCipher.open(ciphertext, key: avatar.key, digest: avatar.digest) {
                    avatarData = plaintext
                    avatarId = avatar.id
                } else {
                    // Download failed — don't advance the revision so the next delivery retries.
                    avatarReady = false
                }
            }
        } else {
            avatarData = nil // peer cleared their photo
            avatarId = nil
        }
        // Only advance to the new revision when the avatar was processed successfully.
        // Keeping the old revision means the next profile delivery retries the download.
        let revisionToStore = avatarReady ? profile.revision : (existing?.revision ?? 0)
        do {
            try storage.messages.upsertProfile(
                account: profile.account,
                displayName: profile.displayName.isEmpty ? nil : profile.displayName,
                avatarId: avatarId, avatarData: avatarData, revision: revisionToStore
            )
        } catch {
            log.error("applyPeerProfile: upsertProfile failed: \(PrivacyRedactor.error(error))")
        }
        // Invalidate caches so the new name/avatar are picked up on next access.
        nameCache[profile.account] = nil
        avatarCache[profile.account] = nil
        refreshConversations()
        if let id = activeConversationId { refreshActiveMessages(ifShowing: id) }
    }

    /// A peer's avatar image bytes from their profile. Cached in memory to avoid
    /// loading large blobs from the DB on every render pass.
    func peerAvatarData(forAccount account: String) -> Data? {
        // Own account avatar lives in the local KV store, not the peer profiles table.
        if account == credentials.accountId { return myAvatarData }
        if avatarCache.keys.contains(account) { return avatarCache[account] ?? nil }
        let data = ((try? storage.messages.peerProfile(account: account)) ?? nil)?.avatarData
        if avatarCache.count >= 200 { avatarCache.removeAll() }
        avatarCache[account] = data
        return data
    }

    func refreshCallHistory() {
        do {
            callHistory = try storage.messages.calls()
        } catch {
            log.error("refresh call history failed: \(PrivacyRedactor.error(error))")
        }
    }

    func clearCallHistory() {
        do {
            try storage.messages.clearCalls()
            callHistory = []
        } catch {
            log.error("clear call history failed: \(PrivacyRedactor.error(error))")
        }
    }

    func recordCall(_ call: StoredCall) {
        do {
            try storage.messages.upsertCall(call)
            refreshCallHistory()
            insertCallSystemMessage(call)
        } catch {
            log.error("record call failed: \(PrivacyRedactor.error(error))")
        }
    }

    private func insertCallSystemMessage(_ call: StoredCall) {
        guard let conversationId = existingConversation(withPeer: call.peerAccount) else { return }
        let kindWord = call.kind == .video ? "video" : "audio"
        let text: String
        switch (call.direction, call.outcome) {
        case (.incoming, .missed):
            text = "Missed \(kindWord) call"
        case (.incoming, .declined):
            text = "Declined \(kindWord) call"
        case (.outgoing, .missed), (.outgoing, .declined), (.outgoing, .failed):
            text = "Outgoing \(kindWord) call"
        default:
            if let connected = call.connectedAt, let ended = call.endedAt, ended > connected {
                let secs = Int((ended - connected) / 1000)
                let label = String(format: "%d:%02d", secs / 60, secs % 60)
                text = call.direction == .incoming
                    ? "Incoming \(kindWord) call · \(label)"
                    : "\(kindWord.capitalized) call · \(label)"
            } else {
                text = call.direction == .incoming ? "Incoming \(kindWord) call" : "\(kindWord.capitalized) call"
            }
        }
        // "call:" prefix lets ChatView render these with an SF Symbol phone icon.
        let body = "call:\(text)"
        _ = try? storage.messages.insertMessage(
            id: UUID().uuidString,
            conversationId: conversationId,
            isOutgoing: false,
            body: body,
            timestamp: call.startedAt,
            status: .received,
            senderAccount: Self.systemSender
        )
        refreshConversations()
        refreshActiveMessages(ifShowing: conversationId)
    }

    private func readKVInt(_ key: String) -> Int64 {
        guard let data = ((try? storage.database.query(
            "SELECT value FROM kv WHERE key = ?", [.text(key)]).first?.first?.data) ?? nil),
              let string = String(data: data, encoding: .utf8), let value = Int64(string)
        else { return 0 }
        return value
    }

    private func writeKVInt(_ key: String, _ value: Int64) {
        try? storage.database.run(
            "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
            [.text(key), .blob(Data(String(value).utf8))]
        )
    }

    private func cachedUsername(_ account: String) -> String? {
        (try? storage.database.query(
            "SELECT value FROM kv WHERE key = ?", [.text("un:\(account)")]
        ).first?.first?.data).flatMap { $0 }.flatMap { String(bytes: $0, encoding: .utf8) }
    }

    private func cacheUsername(_ account: String, _ username: String) {
        try? storage.database.run(
            "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
            [.text("un:\(account)"), .blob(Data(username.utf8))]
        )
    }

    // MARK: - Draft persistence

    func readDraft(for conversationId: String) -> String {
        let key = "draft:\(conversationId)"
        return (try? storage.database.query(
            "SELECT value FROM kv WHERE key = ?", [.text(key)]
        ).first?.first?.data).flatMap { $0 }.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
    }

    func saveDraft(_ text: String, for conversationId: String) {
        let key = "draft:\(conversationId)"
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? storage.database.run("DELETE FROM kv WHERE key = ?", [.text(key)])
        } else {
            try? storage.database.run(
                "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
                [.text(key), .blob(Data(text.utf8))]
            )
        }
    }

    // MARK: - Shared notepad

    func notepadContent(for conversationId: String) -> String {
        let key = "notepad:\(conversationId)"
        return (try? storage.database.query(
            "SELECT value FROM kv WHERE key = ?", [.text(key)]
        ).first?.first?.data).flatMap { $0 }.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
    }

    func setNotepadContent(_ content: String, for conversationId: String) {
        let key = "notepad:\(conversationId)"
        try? storage.database.run(
            "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
            [.text(key), .blob(Data(content.utf8))]
        )
    }

    func sendNotepadUpdate(_ content: String, in conversationId: String) async {
        let body = notepadPrefix + content
        await sendMessage(body, in: conversationId)
        setNotepadContent(content, for: conversationId)
    }

    // MARK: - Scheduled messages

    struct ScheduledMessage: Codable, Identifiable {
        let id: String
        let conversationId: String
        let body: String
        let scheduledAt: Double  // Unix timestamp (seconds)
    }

    func scheduleMessage(_ body: String, in conversationId: String, at date: Date) {
        let msg = ScheduledMessage(
            id: UUID().uuidString,
            conversationId: conversationId,
            body: body,
            scheduledAt: date.timeIntervalSince1970
        )
        guard let data = try? JSONEncoder().encode(msg) else { return }
        try? storage.database.run(
            "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
            [.text("sched:\(msg.id)"), .blob(data)]
        )
    }

    func scheduledMessages() -> [ScheduledMessage] {
        let rows = (try? storage.database.query(
            "SELECT value FROM kv WHERE key LIKE 'sched:%'"
        )) ?? []
        return rows.compactMap { row -> ScheduledMessage? in
            guard let data = row.first?.data else { return nil }
            return try? JSONDecoder().decode(ScheduledMessage.self, from: data)
        }.sorted { $0.scheduledAt < $1.scheduledAt }
    }

    func cancelScheduled(id: String) {
        try? storage.database.run("DELETE FROM kv WHERE key = ?", [.text("sched:\(id)")])
    }

    private func flushDueScheduledMessages() async {
        let now = Date().timeIntervalSince1970
        let due = scheduledMessages().filter { $0.scheduledAt <= now }
        for msg in due {
            cancelScheduled(id: msg.id)
            await sendMessage(msg.body, in: msg.conversationId)
        }
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
        _ = try? storage.messages.insertMessage(
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
            let account = try await resolveAccount(username: username)
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
        insertSystemLine("You created \"\(name)\"", inGroup: gs.id)
        await resolveUsernames(gs.members)
        return try storage.messages.groupConversationId(groupId: gs.id) ?? ""
    }

    func addGroupMember(username: String, toGroup groupId: String) async throws {
        let account = try await resolveAccount(username: username)
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

    func renameGroup(groupId: String, name: String) async throws {
        let gs = try await api.renameGroup(groupId: groupId, name: name)
        try storage.messages.upsertGroup(id: gs.id, name: gs.name, distributionId: gs.distributionId, revision: gs.revision, members: gs.members)
        refreshConversations()
        if let stored = try storage.messages.group(id: gs.id) {
            var update = Relay_Content_GroupUpdate()
            update.action = .rename
            update.name = name
            await sendGroupUpdateCustom(update, group: stored)
        }
        insertSystemLine("You renamed the group to \"\(name)\"", inGroup: groupId)
    }

    func setGroupDescription(_ description: String, groupId: String) async throws {
        let gs = try await api.setGroupDescription(groupId: groupId, description: description)
        try storage.messages.upsertGroup(id: gs.id, name: gs.name, distributionId: gs.distributionId, revision: gs.revision, members: gs.members)
        try storage.messages.setGroupDescription(id: groupId, description: description)
        refreshConversations()
        if let stored = try storage.messages.group(id: gs.id) {
            var update = Relay_Content_GroupUpdate()
            update.action = .describe
            update.description_p = description
            await sendGroupUpdateCustom(update, group: stored)
        }
        insertSystemLine("You updated the group description", inGroup: groupId)
    }

    func setGroupAvatar(_ data: Data, groupId: String) async throws {
        let sealed = try AttachmentCipher.seal(data)
        let blobId = try await api.uploadAttachment(sealed.ciphertext)
        _ = try await api.setGroupAvatarId(groupId: groupId, avatarId: blobId)
        try storage.messages.setGroupAvatar(id: groupId, avatarData: data)
        refreshConversations()
        if let stored = try storage.messages.group(id: groupId) {
            var update = Relay_Content_GroupUpdate()
            update.action = .avatar
            var ptr = Relay_Content_AttachmentPointer()
            ptr.id = blobId
            ptr.key = sealed.key
            ptr.digest = sealed.digest
            ptr.contentType = "image/jpeg"
            update.avatar = ptr
            await sendGroupUpdateCustom(update, group: stored)
        }
    }

    func createGroupInviteLink(groupId: String) async throws -> String {
        let resp = try await api.createGroupInvite(groupId: groupId)
        return resp.url
    }

    // MARK: - Device linking

    /// Provisions a new linked device: registers it on the server, then returns
    /// a JSON payload for embedding in a QR code for the new device to scan.
    func provisionLinkedDevice(syncConversations: Bool, syncHistory: Bool = false) async throws -> String {
        let authorization = try await deviceMutationAuthorization(action: "link", targetDeviceId: 0, password: "")
        let invitation = try await api.createDeviceLinkInvitation(authorization: authorization)
        var payload: [String: Any] = [
            "linkToken": invitation.linkToken,
            "verificationCode": invitation.verificationCode,
            "expiresAt": invitation.expiresAt,
            "serverURL": serverURL.absoluteString
        ]
        if let u = username { payload["username"] = u }
        let convList = conversations.filter { $0.groupId == nil && !$0.peerAccount.isEmpty }
        if syncConversations {
            let stubs: [[String: String]] = convList
                .prefix(50)
                .map { conv in
                    var d = ["account": conv.peerAccount]
                    if let u = conv.peerUsername { d["username"] = u }
                    return d
                }
            if !stubs.isEmpty { payload["peers"] = stubs }
        }
        if syncHistory {
            // Package the last 50 messages per conversation (capped at 500 total),
            // encrypt with a fresh AES-GCM key, upload to relay, and embed the
            // blob id + key + digest so the linked device can download and import them.
            if let (attachmentId, key, digest) = try? await buildAndUploadHistory(conversations: convList) {
                payload["historyId"] = attachmentId
                payload["historyKey"] = key.base64EncodedString()
                payload["historyDigest"] = digest.base64EncodedString()
            }
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return String(data: data, encoding: .utf8) ?? ""
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

    /// Downloads and imports a history blob uploaded by the primary device during linking.
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

    /// Creates empty conversation stubs for a list of peers — used by the linked
    /// device after scanning a QR that included conversation sync data.
    func importConversationStubs(_ peers: [(account: String, username: String?)]) {
        for (account, uname) in peers {
            guard !account.isEmpty else { continue }
            _ = try? storage.messages.conversation(withPeer: account, username: uname)
        }
        refreshConversations()
    }

    func listLinkedDevices() async throws -> [RelayKit.LinkedDevice] {
        try await api.listDevices()
    }

    // MARK: - Nuke (remote wipe / crypto-shred)

    /// Builds and posts a signed remote-wipe command to the relay server.
    /// All devices on the account receive it and wipe themselves.
    func sendNukeCommand() async throws {
        let commandId = UUID().uuidString
        let creationTimeMs = Int64(Date().timeIntervalSince1970 * 1000)
        let initiatingDeviceId = credentials.deviceId
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

    /// Verifies and processes an incoming signed nuke command.
    private func handleNukeEvent(_ nuke: NukeEvent) async {
        // Only process nukes for our own account.
        guard nuke.accountId == credentials.accountId else {
            log.warning("nuke: received command for wrong account, ignoring")
            return
        }
        // Freshness check: reject commands more than 5 minutes old.
        let ageMs = Int64(Date().timeIntervalSince1970 * 1000) - nuke.creationTimeMs
        guard ageMs >= -30_000 && ageMs <= 5 * 60 * 1000 else {
            log.warning("nuke: command timestamp out of acceptable range, ignoring")
            return
        }
        // Verify the ECDSA-P256 signature using the initiating device's auth key.
        do {
            let authKey = try await api.deviceAuthKey(deviceId: nuke.initiatingDeviceId)
            let payload = nukeCanonicalPayload(
                accountId: nuke.accountId,
                commandId: nuke.commandId,
                creationTimeMs: nuke.creationTimeMs,
                initiatingDeviceId: nuke.initiatingDeviceId
            )
            let keyAttrs: [CFString: Any] = [
                kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass: kSecAttrKeyClassPublic,
            ]
            var importError: Unmanaged<CFError>?
            guard let secKey = SecKeyCreateWithData(authKey as CFData, keyAttrs as CFDictionary, &importError) else {
                log.warning("nuke: failed to import initiating device auth key")
                return
            }
            var verifyError: Unmanaged<CFError>?
            let valid = SecKeyVerifySignature(
                secKey,
                .ecdsaSignatureMessageX962SHA256,
                Data(payload.utf8) as CFData,
                nuke.signature as CFData,
                &verifyError
            )
            guard valid else {
                log.warning("nuke: signature verification failed, ignoring")
                return
            }
        } catch {
            log.warning("nuke: could not fetch initiating device auth key: \(error)")
            return
        }
        log.info("nuke: verified command from device \(nuke.initiatingDeviceId), executing wipe")
        await onNukeReceived?()
    }

    private func refreshDeviceList() async throws {
        _ = try await api.listDevices()
        // A device was added or removed. Clear the own-account session cache so
        // the next outgoing sync re-discovers the new device list immediately.
        resetSession(withPeer: credentials.accountId)
    }

    private func nukeCanonicalPayload(accountId: String, commandId: String, creationTimeMs: Int64, initiatingDeviceId: UInt32) -> String {
        ["relay-nuke-v1", accountId, commandId, String(creationTimeMs), String(initiatingDeviceId)].joined(separator: "\n")
    }

    func removeLinkedDevice(deviceId: UInt32) async throws {
        let authorization = try await deviceMutationAuthorization(action: "remove", targetDeviceId: deviceId, password: "")
        try await api.removeDevice(deviceId: deviceId, authorization: authorization)
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

    func joinGroupByInvite(token: String) async throws -> String {
        let gs = try await api.joinGroupByInvite(token: token)
        try storage.messages.upsertGroup(id: gs.id, name: gs.name, distributionId: gs.distributionId, revision: gs.revision, members: gs.members)
        refreshConversations()
        if let stored = try storage.messages.group(id: gs.id) {
            try? await distributeSenderKeyIfNeeded(group: stored)
        }
        insertSystemLine("You joined via invite link", inGroup: gs.id)
        await resolveUsernames(gs.members)
        return try storage.messages.groupConversationId(groupId: gs.id) ?? ""
    }

    func leaveGroup(_ groupId: String) async throws {
        let gs = try await api.removeGroupMember(groupId: groupId, account: credentials.accountId)
        let remaining = StoredGroup(id: gs.id, name: gs.name, distributionId: gs.distributionId, revision: gs.revision, members: gs.members)
        await sendGroupUpdate(.leave, group: remaining, target: credentials.accountId)
        try storage.messages.upsertGroup(id: gs.id, name: gs.name, distributionId: gs.distributionId, revision: gs.revision, members: gs.members)
        refreshConversations()
        insertSystemLine("You left", inGroup: gs.id)
    }

    /// Sends our profile to any group member who hasn't received the current revision.
    private func distributeProfileToGroupMembersIfNeeded(group: StoredGroup) async {
        let rev = myProfileRevision
        guard rev > 0 else { return }
        let needsProfile = group.members.filter {
            $0 != credentials.accountId && readKVInt("pfsent:\($0)") < rev
        }
        for member in needsProfile {
            await sendMyProfileIfNeeded(toPeer: member)
        }
    }

    private func sendGroupMessage(
        _ text: String, in conversationId: String, group: StoredGroup,
        replyTo: QuotedMessage?, attachments pending: [PendingAttachment]
    ) async {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let localId = UUID().uuidString
        guard let distributionId = UUID(uuidString: group.distributionId) else { return }
        var messageInserted = false
        do {
            // Sealed groups fan out as pairwise sealed messages (below), which
            // don't use sender keys — so skip SKDM distribution entirely.
            if !sealedSenderEnabled {
                try await distributeSenderKeyIfNeeded(group: group)
            }
            await distributeProfileToGroupMembersIfNeeded(group: group)
            let (storedAttachments, pointers) = try await encryptAttachments(pending)

            try storage.messages.insertMessage(
                id: localId, conversationId: conversationId, isOutgoing: true,
                body: text, timestamp: timestamp, status: .sending,
                replyTo: replyTo, attachments: storedAttachments,
                senderAccount: credentials.accountId
            )
            messageInserted = true
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
            content.senderAccountID = credentials.accountId
            content.senderDeviceID = credentials.deviceId
            let disappearSecs = conversations.first(where: { $0.id == conversationId })?.disappearingSeconds ?? 0
            if disappearSecs > 0 { content.expiresAfterMs = disappearSecs * 1000 }

            // Opt-in cover-traffic delay before the wire send (message already
            // shows locally as "sending").
            await applySendJitter()
            if sealedSenderEnabled {
                // Sealed groups: fan out as individual pairwise sealed messages.
                // The group id inside the encrypted content still routes each copy
                // to the group conversation on the recipient, but the relay learns
                // neither the sender nor that these deliveries form one group send.
                // (Sender-key broadcast can't be per-recipient sealed without
                // multi-recipient sealing; pairwise is simpler and fully private —
                // fine for the small groups Relay targets.)
                let payload = try content.serializedData()
                for member in group.members where member != credentials.accountId {
                    try await sendContent(payload, toPeer: member, clientTimestamp: timestamp)
                }
            } else {
                // Encrypt once with our sender key, fan the same ciphertext out.
                let sealed = try engine.groupEncrypt(try ContentPadding.pad(content.serializedData()), distributionId: distributionId)
                for member in group.members where member != credentials.accountId {
                    try await sendEncrypted(sealed, toPeer: member, clientTimestamp: timestamp)
                }
            }
            try storage.messages.updateStatus(messageId: localId, status: .sent)
        } catch {
            log.error("group send failed: \(PrivacyRedactor.error(error))")
            if messageInserted {
                do {
                    try storage.messages.updateStatus(messageId: localId, status: .failed)
                } catch {
                    log.error("group send: could not mark message failed: \(PrivacyRedactor.error(error))")
                }
            }
            if let safetyError = error as? SafetyNumberChangedError {
                noteBlockedSafetyWarning(peer: safetyError.peer)
            }
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
                log.warning("SKDM send failed: \(PrivacyRedactor.error(error))")
            }
        }
        saveStringArray(key, Array(sent))
    }

    private func sendGroupUpdate(_ action: Relay_Content_GroupUpdate.Action, group: StoredGroup, target: String) async {
        var update = Relay_Content_GroupUpdate()
        update.action = action
        update.target = target
        await sendGroupUpdateCustom(update, group: group)
    }

    private func sendGroupUpdateCustom(_ update: Relay_Content_GroupUpdate, group: StoredGroup) async {
        var u = update
        u.actor = credentials.accountId
        u.name = group.name
        u.revision = group.revision
        // Include full member list so recipients can update their local roster
        // without a server round-trip (client-managed groups).
        u.members = group.members
        var content = Relay_Content_Content()
        content.groupUpdate = u
        content.groupID = group.id
        content.senderAccountID = credentials.accountId
        content.senderDeviceID = credentials.deviceId
        guard let data = try? content.serializedData() else { return }
        for member in group.members where member != credentials.accountId {
            try? await sendContent(data, toPeer: member, clientTimestamp: Int64(Date().timeIntervalSince1970 * 1000))
        }
    }

    /// Fans an already-encrypted message (e.g. a sender-key group message) to
    /// every device of `account`, with the same mismatch-retry as 1:1 sends.
    private func sendEncrypted(_ message: SecureMessage, toPeer account: String, clientTimestamp: Int64) async throws {
        guard socket != nil else { throw RelayWebSocketError.notConnected }
        try requireAcknowledgedIdentity(forPeer: account)
        var devices = try await knownMailboxDevices(ofPeer: account)
        func payloads(for devices: [PeerDevice]) -> [(mailboxId: String, payload: DeviceMessagePayload)] {
            devices.compactMap { device in
                guard let mailboxId = device.mailboxId, !mailboxId.isEmpty else { return nil }
                return (
                    mailboxId,
                    DeviceMessagePayload(deviceId: device.id, registrationId: device.registrationId, message: message)
                )
            }
        }
        let firstRoundIds = Set(devices.map { $0.id })
        var outcome = try await sendMailboxPayloads(payloads(for: devices), clientTimestamp: clientTimestamp)
        if case .mismatchedDevices(let missing, _, let stale) = outcome {
            try await refreshSessions(withPeer: account)
            try requireAcknowledgedIdentity(forPeer: account)
            devices = try await knownMailboxDevices(ofPeer: account)
            let retryIds = Set(missing).subtracting(firstRoundIds).union(Set(stale))
            if !retryIds.isEmpty {
                let retryDevices = devices.filter { retryIds.contains($0.id) }
                outcome = try await sendMailboxPayloads(payloads(for: retryDevices), clientTimestamp: clientTimestamp)
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
            throw RelayAPIError.http(status: 0, message: "group send rejected: \(outcome)")
        }
    }

    /// Updates the local group roster from the E2E GroupUpdate message.
    /// No server round-trip needed: the sender includes the full member list.
    private func handleGroupUpdate(_ info: GroupUpdateInfo) async {
        if info.action == .remove, info.target == credentials.accountId { return }

        // Description/avatar carry their payload in the message itself.
        if info.action == .describe {
            do {
                try storage.messages.setGroupDescription(id: info.groupId, description: info.description)
                refreshConversations()
                if let line = systemLine(for: info) { insertSystemLine(line, inGroup: info.groupId) }
            } catch { log.warning("group description update failed: \(PrivacyRedactor.error(error))") }
            return
        }
        if info.action == .avatar, !info.avatarId.isEmpty {
            Task {
                do {
                    let ciphertext = try await api.downloadAttachment(id: info.avatarId)
                    let data = try AttachmentCipher.open(ciphertext, key: info.avatarKey, digest: info.avatarDigest)
                    try storage.messages.setGroupAvatar(id: info.groupId, avatarData: data)
                    refreshConversations()
                } catch { log.warning("group avatar download failed: \(PrivacyRedactor.error(error))") }
            }
            return
        }

        // Admin and announce-only updates carry their payload directly.
        if info.action == .promoteAdmin || info.action == .demoteAdmin {
            do {
                try storage.messages.setGroupAdmins(id: info.groupId, admins: info.admins)
                refreshConversations()
                if let line = systemLine(for: info) { insertSystemLine(line, inGroup: info.groupId) }
            } catch { log.warning("group admin update failed: \(PrivacyRedactor.error(error))") }
            return
        }
        if info.action == .setAnnounceOnly {
            do {
                try storage.messages.setGroupAnnounceOnly(id: info.groupId, isAnnounceOnly: info.announceOnly)
                refreshConversations()
                if let line = systemLine(for: info) { insertSystemLine(line, inGroup: info.groupId) }
            } catch { log.warning("group announce-only update failed: \(PrivacyRedactor.error(error))") }
            return
        }

        // Use the E2E member list when present; fall back to server fetch for
        // legacy messages (sent by older clients without the members field).
        if !info.members.isEmpty {
            do {
                let existing = try? storage.messages.group(id: info.groupId)
                let distributionId = existing?.distributionId ?? UUID().uuidString
                try storage.messages.upsertGroup(
                    id: info.groupId, name: info.name.isEmpty ? (existing?.name ?? "") : info.name,
                    distributionId: distributionId, revision: info.revision,
                    members: info.members,
                    admins: info.admins.isEmpty ? (existing?.admins ?? []) : info.admins
                )
                refreshConversations()
                if let convoId = try? storage.messages.groupConversationId(groupId: info.groupId) {
                    refreshActiveMessages(ifShowing: convoId)
                }
                await resolveUsernames(info.members)
                if let line = systemLine(for: info) { insertSystemLine(line, inGroup: info.groupId) }
            } catch {
                log.warning("group update failed: \(PrivacyRedactor.error(error))")
            }
            return
        }

        // Legacy fallback: member list not in E2E message — ask server.
        do {
            let gs = try await api.fetchGroup(id: info.groupId)
            try storage.messages.upsertGroup(
                id: gs.id, name: gs.name, distributionId: gs.distributionId, revision: gs.revision,
                members: gs.members, admins: gs.admins, isAnnounceOnly: gs.announceOnly
            )
            refreshConversations()
            if let convoId = try storage.messages.groupConversationId(groupId: gs.id) {
                refreshActiveMessages(ifShowing: convoId)
            }
            await resolveUsernames(gs.members)
            if let line = systemLine(for: info) { insertSystemLine(line, inGroup: info.groupId) }
        } catch {
            log.warning("group sync failed: \(PrivacyRedactor.error(error))")
        }
    }

    private func systemLine(for info: GroupUpdateInfo) -> String? {
        let actor = displayName(forAccount: info.actor)
        switch info.action {
        case .create: return "\(actor) created the group"
        case .add: return "\(actor) added \(displayName(forAccount: info.target))"
        case .remove: return "\(actor) removed \(displayName(forAccount: info.target))"
        case .leave: return "\(actor) left"
        case .rename: return "\(actor) renamed the group to \"\(info.name)\""
        case .describe: return "\(actor) updated the group description"
        case .avatar: return "\(actor) updated the group photo"
        case .promoteAdmin: return "\(actor) made \(displayName(forAccount: info.target)) an admin"
        case .demoteAdmin: return "\(actor) removed \(displayName(forAccount: info.target)) as admin"
        case .setAnnounceOnly: return info.announceOnly
            ? "\(actor) turned on announce-only mode"
            : "\(actor) turned off announce-only mode"
        case .unknown: return nil
        }
    }

    // MARK: - Admin management

    func promoteAdmin(in groupId: String, account: String) async throws {
        let g = try await api.promoteGroupAdmin(groupId: groupId, account: account)
        try storage.messages.setGroupAdmins(id: groupId, admins: g.admins)
        guard let grp = try? storage.messages.group(id: groupId) else { return }
        var update = Relay_Content_GroupUpdate()
        update.action = .promoteAdmin
        update.target = account
        update.admins = g.admins
        await sendGroupUpdateCustom(update, group: grp)
        insertSystemLine("\(displayName(forAccount: credentials.accountId)) made \(displayName(forAccount: account)) an admin", inGroup: groupId)
        refreshConversations()
    }

    func demoteAdmin(in groupId: String, account: String) async throws {
        let g = try await api.demoteGroupAdmin(groupId: groupId, account: account)
        try storage.messages.setGroupAdmins(id: groupId, admins: g.admins)
        guard let grp = try? storage.messages.group(id: groupId) else { return }
        var update = Relay_Content_GroupUpdate()
        update.action = .demoteAdmin
        update.target = account
        update.admins = g.admins
        await sendGroupUpdateCustom(update, group: grp)
        insertSystemLine("\(displayName(forAccount: credentials.accountId)) removed \(displayName(forAccount: account)) as admin", inGroup: groupId)
        refreshConversations()
    }

    func setAnnounceOnly(_ enabled: Bool, in groupId: String) async throws {
        _ = try await api.setGroupAnnounceOnly(groupId: groupId, announceOnly: enabled)
        try storage.messages.setGroupAnnounceOnly(id: groupId, isAnnounceOnly: enabled)
        guard let grp = try? storage.messages.group(id: groupId) else { return }
        var update = Relay_Content_GroupUpdate()
        update.action = .setAnnounceOnly
        update.announceOnly = enabled
        await sendGroupUpdateCustom(update, group: grp)
        let line = enabled ? "You turned on announce-only mode" : "You turned off announce-only mode"
        insertSystemLine(line, inGroup: groupId)
        refreshConversations()
    }

    func isAdmin(in conversationId: String) -> Bool {
        guard let grp = group(for: conversationId) else { return false }
        return grp.admins.contains(credentials.accountId)
    }

    func isAnnounceOnly(conversationId: String) -> Bool {
        group(for: conversationId)?.isAnnounceOnly ?? false
    }

    // MARK: - Polls

    func sendPoll(question: String, options: [String], multiSelect: Bool, in conversationId: String) async {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let localId = UUID().uuidString
        var poll = Relay_Content_PollMessage()
        poll.question = question
        poll.options = options
        poll.multiSelect = multiSelect
        poll.timestamp = timestamp
        var content = Relay_Content_Content()
        content.poll = poll
        content.senderAccountID = credentials.accountId
        content.senderDeviceID = credentials.deviceId
        refreshActiveMessages(ifShowing: conversationId)
        do {
            let pollPayload = PollPayload(question: question, options: options, multiSelect: multiSelect)
            let pollBody = "__poll__:" + (pollPayload.encode() ?? question)
            try storage.messages.insertMessage(
                id: localId, conversationId: conversationId, isOutgoing: true,
                body: pollBody, timestamp: timestamp, status: .sending
            )
            guard let data = try? content.serializedData() else { return }
            let targets = pollTargets(for: conversationId, content: &content)
            for peer in targets {
                try await sendContent(data, toPeer: peer, clientTimestamp: timestamp)
            }
            try? storage.messages.updateStatus(messageId: localId, status: .sent)
        } catch {
            log.warning("poll send failed: \(PrivacyRedactor.error(error))")
            try? storage.messages.updateStatus(messageId: localId, status: .failed)
        }
    }

    func sendPollVote(pollAuthor: String, pollTimestamp: Int64, selectedOptions: [Int], in conversationId: String) async {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        try? storage.messages.upsertPollVote(
            conversationId: conversationId, pollAuthor: pollAuthor, pollTimestamp: pollTimestamp,
            voterAccount: credentials.accountId, selectedOptions: selectedOptions, votedAt: timestamp
        )
        refreshActiveMessages(ifShowing: conversationId)
        var vote = Relay_Content_PollVote()
        vote.pollAuthor = pollAuthor
        vote.pollTimestamp = pollTimestamp
        vote.selectedOptions = selectedOptions.map { UInt32($0) }
        vote.timestamp = timestamp
        var content = Relay_Content_Content()
        content.pollVote = vote
        content.senderAccountID = credentials.accountId
        content.senderDeviceID = credentials.deviceId
        guard let data = try? content.serializedData() else { return }
        let targets = pollTargets(for: conversationId, content: &content)
        for peer in targets {
            try? await sendContent(data, toPeer: peer, clientTimestamp: timestamp)
        }
    }

    private func pollTargets(for conversationId: String, content: inout Relay_Content_Content) -> [String] {
        if let grp = group(for: conversationId) {
            content.groupID = grp.id
            return grp.members.filter { $0 != credentials.accountId }
        }
        if let peer = try? peerAccount(for: conversationId) {
            return [peer]
        }
        return []
    }

    func pollVotes(conversationId: String, pollAuthor: String, pollTimestamp: Int64) -> [StoredPollVote] {
        (try? storage.messages.pollVotes(conversationId: conversationId, pollAuthor: pollAuthor, pollTimestamp: pollTimestamp)) ?? []
    }

    private func encryptAttachments(
        _ pending: [PendingAttachment]
    ) async throws -> ([StoredAttachment], [Relay_Content_AttachmentPointer]) {
        // 25 MB plaintext limit — the server enforces 26 MB on the ciphertext side,
        // and AES-GCM overhead is negligible, so this check avoids wasting time
        // encrypting something that will be rejected.
        let maxPlaintextBytes = 25 * 1024 * 1024
        var stored: [StoredAttachment] = []
        var pointers: [Relay_Content_AttachmentPointer] = []
        for item in pending {
            guard item.data.count <= maxPlaintextBytes else {
                throw MessagingError.attachmentTooLarge
            }
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

    /// All messages in a conversation (not just the active one). Used by
    /// MediaGalleryView which may open from ContactCardView when another
    /// conversation is active.
    func allMessages(in conversationId: String) throws -> [StoredMessage] {
        try storage.messages.messages(in: conversationId)
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
        toPeer account: String,
        groupId: String? = nil
    ) async {
        var content = Relay_Content_Content()
        content.receipt.type = type
        content.receipt.messageTimestamps = timestamps
        if let groupId { content.groupID = groupId }
        do {
            try await sendContent(
                try content.serializedData(),
                toPeer: account,
                clientTimestamp: Int64(Date().timeIntervalSince1970 * 1000),
                ephemeral: true
            )
        } catch {
            log.warning("receipt send failed: \(PrivacyRedactor.error(error))")
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
        guard socket != nil else { throw RelayWebSocketError.notConnected }
        if !ephemeral {
            try requireAcknowledgedIdentity(forPeer: account)
        }
        let payloadPlaintext = ephemeral ? plaintext : try ContentPadding.pad(plaintext)
        // Sealed sender: route through the unauthenticated delivery path so the
        // relay never learns the sender. Receiving handles both formats, so this
        // is safe to flip on independently per device.
        if sealedSenderEnabled {
            try await sendContentSealed(
                payloadPlaintext, toPeer: account,
                clientTimestamp: clientTimestamp, ephemeral: ephemeral
            )
            return
        }
        var devices = try await knownMailboxDevices(ofPeer: account)
        // Track all device IDs addressed in round 1 so the retry doesn't re-send to
        // devices that already received the message. The server always reports ALL
        // other devices as 'missing' (even already-delivered ones) to inform the sender
        // about linked devices — so we must filter by what was genuinely unaddressed.
        let firstRoundIds = Set(devices.map { $0.id })
        var payloads = try buildMailboxPayloads(payloadPlaintext, forPeer: account, devices: devices)
        var outcome = try await sendMailboxPayloads(
            payloads,
            clientTimestamp: clientTimestamp,
            ephemeral: ephemeral
        )
        if case .mismatchedDevices(let missing, _, let stale) = outcome {
            try await refreshSessions(withPeer: account)
            if !ephemeral {
                try requireAcknowledgedIdentity(forPeer: account)
            }
            devices = try await knownMailboxDevices(ofPeer: account)
            // Only retry devices that were genuinely not addressed in round 1 (newly
            // discovered via missing_devices) plus stale devices (delivery failed).
            // Devices in 'missing' that are already in firstRoundIds were successfully
            // delivered to — the server just echoes them back; re-sending = duplicates.
            let retryIds = Set(missing).subtracting(firstRoundIds).union(Set(stale))
            if !retryIds.isEmpty {
                let retryDevices = devices.filter { retryIds.contains($0.id) }
                payloads = try buildMailboxPayloads(payloadPlaintext, forPeer: account, devices: retryDevices)
                outcome = try await sendMailboxPayloads(
                    payloads,
                    clientTimestamp: clientTimestamp,
                    ephemeral: ephemeral
                )
                // After the retry, any remaining missing/stale that are all within the
                // now-addressed set = success (the server's all-other-devices pattern).
                if case .mismatchedDevices(let m2, let e2, let s2) = outcome, e2.isEmpty {
                    let allAddressedIds = firstRoundIds.union(retryIds)
                    if Set(m2 + s2).isSubset(of: allAddressedIds) {
                        outcome = .ok(serverTimestamp: 0)
                    }
                }
            } else {
                // All reported missing devices were already addressed in round 1.
                outcome = .ok(serverTimestamp: 0)
            }
        }
        guard case .ok = outcome else {
            throw RelayAPIError.http(status: 0, message: "send rejected: \(outcome)")
        }
    }

    /// Sends `plaintext` to every known device of the peer as sealed-sender
    /// messages over the unauthenticated REST endpoint. Unlike the WebSocket
    /// path there's no server-side device-mismatch verdict, so we rely on the
    /// locally-known device list (kept current by `DeviceListChanged` and the
    /// periodic bundle refresh) and re-establish sessions on demand.
    private func sendContentSealed(
        _ plaintext: Data,
        toPeer account: String,
        clientTimestamp: Int64,
        ephemeral: Bool
    ) async throws {
        let certificate = try await senderCertificate()
        // Ensure we have the peer's access key (and sessions) before addressing them.
        if peerAccessKeys[account] == nil {
            try await refreshSessions(withPeer: account)
        }
        guard peerAccessKeys[account] != nil else {
            // The peer hasn't published a sealed-sender access key; we can't
            // reach them privately. Surface as a send failure.
            throw RelayAPIError.http(status: 403, message: "recipient has not enabled sealed sender")
        }

        // First pass to all known devices. A 403 usually means the recipient
        // rotated their mailbox or access key, so refresh once and retry only the
        // devices that failed (retrying all would duplicate already-delivered copies).
        let devices = try await knownMailboxDevices(ofPeer: account)
        var failed = try await sealedSendPass(
            plaintext, toPeer: account, devices: devices, certificate: certificate,
            clientTimestamp: clientTimestamp, ephemeral: ephemeral
        )
        guard !failed.isEmpty else { return }

        try await refreshSessions(withPeer: account)
        let refreshedDevices = try await knownMailboxDevices(ofPeer: account)
        let failedIds = Set(failed.map { $0.id })
        let retryDevices = refreshedDevices.filter { failedIds.contains($0.id) }
        failed = try await sealedSendPass(
            plaintext, toPeer: account, devices: retryDevices, certificate: certificate,
            clientTimestamp: clientTimestamp, ephemeral: ephemeral
        )
        if !failed.isEmpty {
            throw RelayAPIError.http(status: 403, message: "sealed delivery rejected")
        }
    }

    /// Sends `plaintext` sealed to each device; returns the devices that got a
    /// retryable 403 (stale mailbox / access key). Any other error throws.
    private func sealedSendPass(
        _ plaintext: Data,
        toPeer account: String,
        devices: [PeerDevice],
        certificate: Data,
        clientTimestamp: Int64,
        ephemeral: Bool
    ) async throws -> [PeerDevice] {
        // Read the access key fresh each pass so a refresh between passes takes effect.
        guard let accessKey = peerAccessKeys[account] else { return devices }
        var failed: [PeerDevice] = []
        for device in devices {
            guard let mailboxId = device.mailboxId, !mailboxId.isEmpty else { continue }
            let address = try ProtocolAddress(name: account, deviceId: device.id)
            // sealedEncrypt needs an established session; refresh if missing.
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
                    clientTimestamp: clientTimestamp
                )
            } catch let RelayAPIError.http(status, _) where status == 403 {
                failed.append(device)
            }
        }
        return failed
    }

    private func buildMailboxPayloads(
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

    /// Fetches fresh prekey bundles for the peer and (re)establishes
    /// sessions for every device, recording the device list.
    private func refreshSessions(withPeer account: String) async throws {
        let fetched = try await api.fetchPreKeyBundlesWithAccessKey(account: account)
        let bundles = fetched.bundles
        // Cache the peer's sealed-sender access key so we can address them on the
        // unauthenticated delivery path without another round-trip.
        if let accessKey = fetched.accessKey {
            peerAccessKeys[account] = accessKey
        }
        var devices: [PeerDevice] = []
        var firstSeenIdentity = false
        for bundle in bundles {
            let address = try ProtocolAddress(name: account, deviceId: bundle.deviceId)
            try guardIdentityReplacement(bundle.identityKey, peer: account, address: address)
            let hadIdentity = try storage.signalStore.identity(for: address, context: NullContext()) != nil
            // Always re-process: if the peer reinstalled (new identity/prekeys) or a
            // session is corrupted, the mismatch retry must establish a fresh session
            // even when an old one exists in the store.
            try engine.processPeerBundle(bundle, from: address)
            firstSeenIdentity = firstSeenIdentity || !hadIdentity
            devices.append(PeerDevice(id: bundle.deviceId, mailboxId: bundle.mailboxId, registrationId: bundle.registrationId))
        }
        try storeKnownDevices(devices, ofPeer: account)
        if firstSeenIdentity {
            try acknowledgeCurrentIdentity(forPeer: account)
        }
    }

    private func knownMailboxDevices(ofPeer account: String) async throws -> [PeerDevice] {
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

    private func sendMailboxPayloads(
        _ payloads: [(mailboxId: String, payload: DeviceMessagePayload)],
        clientTimestamp: Int64,
        ephemeral: Bool = false
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
                ephemeral: ephemeral
            )
            switch outcome {
            case .ok:
                break
            case .mismatchedDevices(let m, let e, let s):
                // Accumulate mismatch info across all sends and continue —
                // devices after a stale/missing one still need to be addressed.
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

    /// Clears the cached device list for `account` so the next send is forced
    /// to re-fetch prekey bundles and re-establish sessions from scratch.
    func resetSession(withPeer account: String) {
        try? storage.database.run(
            "DELETE FROM kv WHERE key = ?", [.text("peer-devices:\(account)")]
        )
    }

    // MARK: - Read state

    func openConversation(_ conversationId: String) {
        activeConversationId = conversationId
        activeMessages = []
        messagesLoadedConversationId = nil
        cachedActiveGroup = group(for: conversationId)  // cache to avoid per-message DB queries
        refreshActiveMessages(ifShowing: conversationId)
        Task { await markVisibleMessagesRead(in: conversationId) }
        if cachedActiveGroup == nil, let peer = resolvedPeerAccount(for: conversationId) {
            startPresencePolling(peer: peer)
        } else {
            stopPresencePolling()
        }
        Task {
            if let group = group(for: conversationId) {
                await resolveUsernames(group.members)
            } else if let peer = resolvedPeerAccount(for: conversationId) {
                await resolveUsernames([peer])
                await sendMyProfileIfNeeded(toPeer: peer)
            }
        }
    }

    func closeConversation(id: String) {
        // SwiftUI fires the new view's onAppear before the old view's onDisappear,
        // so openConversation() for the next chat may have already run. Guard here
        // to avoid clobbering the newly-opened conversation's state.
        guard activeConversationId == id else { return }
        activeConversationId = nil
        activeMessages = []
        messagesLoadedConversationId = nil
        cachedActiveGroup = nil
        typingResetTasks[id]?.cancel()
        typingResetTasks.removeValue(forKey: id)
        typingConversations.remove(id)
        stopPresencePolling()
    }

    // MARK: - Presence

    /// The open 1:1 peer's live connection state, refreshed every ~20s while
    /// the chat is on screen. Nil in groups or before the first fetch.
    private(set) var peerPresence: Presence?
    private var presenceTask: Task<Void, Never>?

    private func startPresencePolling(peer: String) {
        presenceTask?.cancel()
        peerPresence = nil
        guard !hideLastSeen else { return }
        presenceTask = Task { [weak self] in
            while !Task.isCancelled {
                if let presence = try? await self?.api.presence(account: peer) {
                    self?.peerPresence = presence
                    self?.presenceCache[peer] = presence
                }
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    /// Latest cached presence for any account seen while a conversation with them was open.
    func presenceFor(account: String) -> Presence? { presenceCache[account] }

    private func stopPresencePolling() {
        presenceTask?.cancel()
        presenceTask = nil
        peerPresence = nil
    }

    private func postMentionNotification(body: String, senderAccount: String) {
        let content = UNMutableNotificationContent()
        content.title = "You were mentioned"
        content.body = body
        content.sound = .default
        let id = "mention-\(senderAccount)-\(Int64(Date().timeIntervalSince1970 * 1000))"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil)
        )
    }

    private func markVisibleMessagesRead(in conversationId: String) async {
        guard let messages = try? storage.messages.messages(in: conversationId) else { return }
        let unread = messages.filter { !$0.isOutgoing && $0.status == .received }
        guard !unread.isEmpty else { return }

        if sendReadReceipts {
            if let group = group(for: conversationId) {
                let byAuthor = Dictionary(grouping: unread) { $0.senderAccount ?? "" }
                for (author, msgs) in byAuthor where !author.isEmpty && author != credentials.accountId {
                    await sendReceipt(.read, timestamps: msgs.map(\.timestamp), toPeer: author, groupId: group.id)
                }
            } else if let peer = try? peerAccount(for: conversationId) {
                await sendReceipt(.read, timestamps: unread.map(\.timestamp), toPeer: peer)
            }
        }
        for message in unread {
            try? storage.messages.updateStatus(messageId: message.id, status: .read)
        }
        try? storage.messages.markConversationRead(conversationId)
        refreshConversations()
    }

    func markConversationRead(_ conversationId: String) {
        do {
            try storage.messages.markConversationRead(conversationId)
            refreshConversations()
        } catch {
            log.error("mark conversation read failed: \(PrivacyRedactor.error(error))")
        }
    }

    func markConversationUnread(_ conversationId: String) {
        do {
            try storage.messages.markConversationUnread(conversationId)
            refreshConversations()
        } catch {
            log.error("mark conversation unread failed: \(PrivacyRedactor.error(error))")
        }
    }

    func setConversationPinned(_ conversationId: String, pinned: Bool) {
        do {
            try storage.messages.setConversationPinned(conversationId, pinned: pinned)
            refreshConversations()
        } catch {
            log.error("set pinned failed: \(PrivacyRedactor.error(error))")
        }
    }

    func setConversationLabel(_ conversationId: String, label: String?) {
        try? storage.messages.setConversationLabel(conversationId, label: label)
        refreshConversations()
    }

    func isConversationMuted(_ id: String) -> Bool {
        guard let expiry = muteExpiries[id] else { return false }
        if expiry == Int64.max { return true }
        return expiry > Int64(Date().timeIntervalSince1970 * 1000)
    }

    // seconds: 0 = unmute, -1 = forever, >0 = duration from now
    func setConversationMuted(_ id: String, muted: Bool) {
        setMuteDuration(id, seconds: muted ? -1 : 0)
    }

    func setMuteDuration(_ id: String, seconds: Int64) {
        if seconds == 0 {
            muteExpiries.removeValue(forKey: id)
        } else if seconds < 0 {
            muteExpiries[id] = Int64.max
        } else {
            muteExpiries[id] = Int64(Date().timeIntervalSince1970 * 1000) + seconds * 1000
        }
        saveMuteExpiries()
    }

    func muteLabel(for id: String) -> String {
        guard let expiry = muteExpiries[id] else { return "Mute" }
        if expiry == Int64.max { return "Muted (forever)" }
        let remaining = expiry - Int64(Date().timeIntervalSince1970 * 1000)
        guard remaining > 0 else { return "Mute" }
        let hours = remaining / 3_600_000
        if hours < 1 { return "Muted (<1h)" }
        if hours < 24 { return "Muted (\(hours)h)" }
        return "Muted (\(hours / 24)d)"
    }

    private func loadMuteExpiries() {
        let ud = UserDefaults(suiteName: AppModel.appGroupId)
        // Migrate old boolean mute set to forever entries
        if let old = ud?.stringArray(forKey: "relay.mutedConversationIds"), !old.isEmpty {
            for id in old { muteExpiries[id] = Int64.max }
            ud?.removeObject(forKey: "relay.mutedConversationIds")
            saveMuteExpiries()
            return
        }
        if let data = ud?.data(forKey: "relay.muteExpiries"),
           let decoded = try? JSONDecoder().decode([String: Int64].self, from: data) {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            muteExpiries = decoded.filter { $0.value == Int64.max || $0.value > now }
        }
    }

    private func saveMuteExpiries() {
        if let data = try? JSONEncoder().encode(muteExpiries) {
            UserDefaults(suiteName: AppModel.appGroupId)?.set(data, forKey: "relay.muteExpiries")
        }
    }

    var sendReadReceipts: Bool {
        get { UserDefaults.standard.object(forKey: "relay.sendReadReceipts") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "relay.sendReadReceipts") }
    }

    var hideLastSeen: Bool {
        get { UserDefaults.standard.bool(forKey: "relay.hideLastSeen") }
        set { UserDefaults.standard.set(newValue, forKey: "relay.hideLastSeen") }
    }

    /// Opt-in cover-traffic timing: when enabled, outbound messages are held for
    /// a short random delay before transmission so the relay (and any network
    /// observer) can't correlate your send with the exact moment you hit send.
    var sendJitterEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "relay.sendJitter") }
        set { UserDefaults.standard.set(newValue, forKey: "relay.sendJitter") }
    }

    /// Opt-in sealed sender: when enabled, outbound messages are sent via the
    /// unauthenticated `/v1/messages/sealed` endpoint so the relay can't see who
    /// sent them (the sender identity is carried inside the E2E-encrypted blob,
    /// attested by a relay-minted certificate). Receiving handles both formats
    /// regardless of this flag, so it's safe to toggle at any time.
    var sealedSenderEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "relay.sealedSender") }
        set { UserDefaults.standard.set(newValue, forKey: "relay.sealedSender") }
    }

    /// Rotates this device's mailbox id at most once a day so the relay can't
    /// track a long-lived routing identifier. Gated on sealed sender: the sealed
    /// path auto-retries on the resulting stale-mailbox 403, whereas the plain
    /// WebSocket path has no such recovery, so we only rotate in private mode.
    private func rotateMailboxIfNeeded() async {
        guard sealedSenderEnabled else { return }
        let key = "relay.lastMailboxRotation"
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: key)
        guard now - last > 86_400 else { return }
        do {
            _ = try await api.rotateMailbox()
            UserDefaults.standard.set(now, forKey: key)
        } catch {
            log.warning("mailbox rotation failed: \(PrivacyRedactor.error(error))")
        }
    }

    /// Returns this device's sealed-sender certificate, fetching (and caching) a
    /// fresh one from the relay when absent or within a day of expiry.
    private func senderCertificate() async throws -> Data {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if let cert = cachedSenderCert, cert.expiresAt - nowMs > 86_400_000 {
            return cert.data
        }
        let fetched = try await api.deliveryCertificate()
        cachedSenderCert = (fetched.certificate, fetched.expiresAt)
        return fetched.certificate
    }

    /// Awaits a random delay (up to ~5s) before an outbound message is sent,
    /// but only when send jitter is enabled. No-op otherwise.
    private func applySendJitter() async {
        guard sendJitterEnabled else { return }
        let delayMs = UInt64.random(in: 500...5000)
        try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
    }

    func starMessage(_ messageId: String, starred: Bool, in conversationId: String) {
        do {
            try storage.messages.setMessageStarred(id: messageId, starred: starred)
            refreshActiveMessages(ifShowing: conversationId)
        } catch {
            log.error("star message failed: \(PrivacyRedactor.error(error))")
        }
    }

    func starredMessages(for conversationId: String) -> [StoredMessage] {
        (try? storage.messages.starredMessages(in: conversationId)) ?? []
    }

    func deleteConversation(_ conversationId: String) {
        if activeConversationId == conversationId { closeConversation(id: conversationId) }
        do {
            try storage.messages.deleteConversation(id: conversationId)
            refreshConversations()
        } catch {
            log.error("delete conversation failed: \(PrivacyRedactor.error(error))")
        }
    }

    func setDisappearingSeconds(_ conversationId: String, seconds: Int64) {
        do {
            try storage.messages.setDisappearingSeconds(conversationId, seconds: seconds)
            refreshConversations()
        } catch {
            log.error("set disappearing messages failed: \(PrivacyRedactor.error(error))")
        }
    }

    func setConversationPrivacy(
        _ conversationId: String,
        mediaRequiresBiometric: Bool,
        requireBiometricChat: Bool,
        hidePreviews: Bool,
        screenSecurity: Bool
    ) {
        do {
            try storage.messages.setConversationPrivacy(
                conversationId,
                mediaRequiresBiometric: mediaRequiresBiometric,
                requireBiometricChat: requireBiometricChat,
                hidePreviews: hidePreviews,
                screenSecurity: screenSecurity
            )
            refreshConversations()
        } catch {
            log.error("set conversation privacy failed: \(PrivacyRedactor.error(error))")
        }
    }

    func setNotificationSound(_ conversationId: String, sound: String?) {
        try? storage.messages.setNotificationSound(conversationId, sound: sound)
        refreshConversations()
    }

    func notificationSound(for conversationId: String) -> String? {
        conversations.first { $0.id == conversationId }?.notificationSound
    }

    func isScreenSecure(_ conversationId: String) -> Bool {
        conversations.first { $0.id == conversationId }?.screenSecurity ?? false
    }

    /// Evicts a view-once attachment from the on-disk cache after it has been viewed.
    func deleteViewOnceAttachment(_ attachment: StoredAttachment, in conversationId: String) {
        attachmentStore.delete(attachment.id)
    }

    func setConversationArchived(_ conversationId: String, archived: Bool) {
        do {
            try storage.messages.setConversationArchived(conversationId, archived: archived)
            refreshConversations()
        } catch {
            log.error("set archived failed: \(PrivacyRedactor.error(error))")
        }
    }


    // MARK: - Pinned messages

    func pinMessage(_ messageId: String, pinned: Bool, in conversationId: String) {
        do {
            try storage.messages.setMessagePinned(id: messageId, pinned: pinned)
            refreshConversations()
            refreshActiveMessages(ifShowing: conversationId)
        } catch {
            log.error("pin message failed: \(PrivacyRedactor.error(error))")
        }
    }

    func pinnedMessage(for conversationId: String) -> StoredMessage? {
        try? storage.messages.pinnedMessage(in: conversationId)
    }

    // MARK: - Block list

    func isBlocked(_ account: String) -> Bool {
        blockedAccounts.contains(account)
    }

    /// Bulk helpers used by ConversationListView's multi-select toolbar.
    func bulkArchive(_ ids: Set<String>) {
        for id in ids { try? storage.messages.setConversationArchived(id, archived: true) }
        refreshConversations()
    }

    func bulkDelete(_ ids: Set<String>) {
        for id in ids { try? storage.messages.deleteConversation(id: id) }
        refreshConversations()
    }

    func bulkMarkRead(_ ids: Set<String>) {
        for id in ids { try? storage.messages.markConversationRead(id) }
        refreshConversations()
    }

    func bulkMute(_ ids: Set<String>) {
        for id in ids { muteExpiries[id] = Int64.max }
        saveMuteExpiries()
    }

    func blockAccount(_ account: String) {
        blockedAccounts.insert(account)
        saveBlockedAccounts()
        refreshConversations()
    }

    func unblockAccount(_ account: String) {
        blockedAccounts.remove(account)
        saveBlockedAccounts()
        refreshConversations()
    }

    private func loadBlockedAccounts() {
        guard let data = (try? storage.database.query(
            "SELECT value FROM kv WHERE key = 'relay.blockedAccounts'"
        ).first?.first?.data) ?? nil,
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return }
        blockedAccounts = Set(list)
    }

    private func saveBlockedAccounts() {
        guard let data = try? JSONEncoder().encode(Array(blockedAccounts)) else { return }
        try? storage.database.run(
            "INSERT OR REPLACE INTO kv (key, value) VALUES ('relay.blockedAccounts', ?)",
            [.blob(data)]
        )
    }

    // MARK: - Note to Self

    /// Ensures a Note to Self conversation exists, creating one if needed.
    /// Uses the caller's own account so messages are delivered back via the
    /// server and go through the normal E2EE path. Returns the conversation id.
    @discardableResult
    func ensureNoteToSelf() async -> String {
        guard let me = username else { return "" }
        return (try? await startConversation(username: me)) ?? ""
    }

    func searchMessages(query: String) -> [MessageStore.SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return (try? storage.messages.searchMessages(query: trimmed)) ?? []
    }

    // MARK: - Group receipt display

    /// Aggregate status for an outgoing group message: read when every other
    /// member has read it, delivered when every member has at least received
    /// it, otherwise the message's own send status.
    func groupAggregateStatus(for message: StoredMessage, in conversationId: String) -> MessageStatus {
        // Use the cached group (set when the conversation was opened) to avoid
        // two DB queries per outgoing message during render.
        guard message.isOutgoing, let group = cachedActiveGroup ?? group(for: conversationId)
        else { return message.status }
        let recipients = group.members.filter { $0 != credentials.accountId }
        guard !recipients.isEmpty else { return message.status }
        let receipts = (try? storage.messages.groupReceipts(
            conversationId: conversationId, messageTimestamp: message.timestamp)) ?? [:]
        let read = recipients.filter { receipts[$0] == .read }.count
        let delivered = recipients.filter { receipts[$0] == .read || receipts[$0] == .delivered }.count
        if read == recipients.count { return .read }
        if delivered == recipients.count { return .delivered }
        return message.status
    }

    /// Per-member receipt state for an outgoing group message, for the info
    /// sheet: (displayName, "Read"/"Delivered"/"Sent") sorted read-first.
    func groupReadReceipts(for message: StoredMessage, in conversationId: String) -> [(name: String, status: String)] {
        guard let group = group(for: conversationId) else { return [] }
        let recipients = group.members.filter { $0 != credentials.accountId }
        let receipts = (try? storage.messages.groupReceipts(
            conversationId: conversationId, messageTimestamp: message.timestamp)) ?? [:]
        func rank(_ s: MessageStatus?) -> Int { s == .read ? 0 : (s == .delivered ? 1 : 2) }
        func label(_ s: MessageStatus?) -> String { s == .read ? "Read" : (s == .delivered ? "Delivered" : "Sent") }
        return recipients
            .map { (account: $0, status: receipts[$0]) }
            .sorted { (rank($0.status), displayName(forAccount: $0.account)) < (rank($1.status), displayName(forAccount: $1.account)) }
            .map { (name: displayName(forAccount: $0.account), status: label($0.status)) }
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

    struct SafetyNumberChangedError: Error {
        let peer: String
    }

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
            var state = try storage.signalStore.verificationState(address: peer)
            if state == .unverified, try isIdentityChangeAwaitingAcknowledgement(forPeer: peer) {
                state = .changed
            }
            return PeerVerification(safetyNumber: safetyNumber, state: state)
        } catch {
            log.error("safety number failed: \(PrivacyRedactor.error(error))")
            return nil
        }
    }

    /// Marks the peer verified, or clears verification (also dismissing a
    /// pending safety-number-changed warning).
    func setVerified(_ verified: Bool, conversationId: String) {
        guard let peer = resolvedPeerAccount(for: conversationId) else { return }
        do {
            try storage.signalStore.setVerified(verified, address: peer)
            if verified {
                try acknowledgeCurrentIdentity(forPeer: peer)
            }
            refreshConversations()
        } catch {
            log.error("setVerified failed: \(PrivacyRedactor.error(error))")
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
                try acknowledgeCurrentIdentity(forPeer: peer)
                refreshConversations()
            }
            return matches
        } catch {
            log.error("verifyScanned failed: \(PrivacyRedactor.error(error))")
            return false
        }
    }

    private func resolvedPeerAccount(for conversationId: String) -> String? {
        (try? peerAccount(for: conversationId)).flatMap { $0 }
    }

    func clearBlockedSafetyWarning() {
        blockedSafetyWarningConversationId = nil
    }

    private static func identityAcknowledgementKey(forPeer peer: String) -> String {
        "peer-identity-ack:\(peer)"
    }

    private func guardIdentityReplacement(_ identityData: Data, peer: String, address: ProtocolAddress) throws {
        let incomingIdentity = try IdentityKey(bytes: identityData)
        guard let knownIdentity = try storage.signalStore.identity(for: address, context: NullContext()),
              knownIdentity != incomingIdentity else {
            return
        }

        _ = try storage.signalStore.saveIdentity(incomingIdentity, for: address, context: NullContext())
        refreshConversations()
        throw SafetyNumberChangedError(peer: peer)
    }

    private func requireAcknowledgedIdentity(forPeer peer: String) throws {
        if try isIdentityChangeAwaitingAcknowledgement(forPeer: peer) {
            throw SafetyNumberChangedError(peer: peer)
        }
    }

    private func isIdentityChangeAwaitingAcknowledgement(forPeer peer: String) throws -> Bool {
        guard let currentIdentity = try currentIdentityData(forPeer: peer) else { return false }
        guard let acknowledgedIdentity = try acknowledgedIdentityData(forPeer: peer) else {
            try acknowledgeCurrentIdentity(forPeer: peer, identity: currentIdentity)
            return false
        }
        return acknowledgedIdentity != currentIdentity
    }

    private func acknowledgeCurrentIdentity(forPeer peer: String) throws {
        guard let identity = try currentIdentityData(forPeer: peer) else { return }
        try acknowledgeCurrentIdentity(forPeer: peer, identity: identity)
    }

    private func acknowledgeCurrentIdentity(forPeer peer: String, identity: Data) throws {
        try storage.database.run(
            "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
            [.text(Self.identityAcknowledgementKey(forPeer: peer)), .blob(identity)]
        )
    }

    private func acknowledgedIdentityData(forPeer peer: String) throws -> Data? {
        try storage.database.query(
            "SELECT value FROM kv WHERE key = ?",
            [.text(Self.identityAcknowledgementKey(forPeer: peer))]
        ).first?.first?.data
    }

    private func currentIdentityData(forPeer peer: String) throws -> Data? {
        try storage.database.query(
            "SELECT identity_key FROM remote_identities WHERE address = ?",
            [.text(peer)]
        ).first?.first?.data
    }

    private func noteBlockedSafetyWarning(peer: String) {
        guard let conversationId = try? storage.messages.conversation(withPeer: peer, username: nil) else { return }
        blockedSafetyWarningConversationId = conversationId
        refreshConversations()
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
            log.error("store reaction failed: \(PrivacyRedactor.error(error))")
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
                log.error("reaction send failed: \(PrivacyRedactor.error(error))")
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
            log.error("delete message failed: \(PrivacyRedactor.error(error))")
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
            log.error("local unsend failed: \(PrivacyRedactor.error(error))")
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
                log.error("unsend send failed: \(PrivacyRedactor.error(error))")
            }
        }
    }

    /// Updates the body of an outgoing message locally and delivers an
    /// EditMessage to the peer so their copy updates too.
    func editMessage(_ message: StoredMessage, newBody: String) {
        let conversationId = message.conversationId
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            try storage.messages.editMessage(
                conversationId: conversationId,
                targetTimestamp: message.timestamp,
                newBody: newBody
            )
            refreshConversations()
            refreshActiveMessages(ifShowing: conversationId)
        } catch {
            log.error("local message edit failed: \(PrivacyRedactor.error(error))")
            return
        }
        guard let peer = resolvedPeerAccount(for: conversationId) else { return }
        Task {
            var content = Relay_Content_Content()
            content.edit.targetTimestamp = message.timestamp
            content.edit.newBody = newBody
            do {
                try await sendContent(try content.serializedData(), toPeer: peer, clientTimestamp: now)
            } catch {
                log.error("edit message send failed: \(PrivacyRedactor.error(error))")
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
                log.debug("typing send skipped: \(PrivacyRedactor.error(error))")
            }
        }
    }

    private func applyPeerTyping(started: Bool, peerAccount: String?) {
        guard let peerAccount,
              let conversationId = existingConversation(withPeer: peerAccount) else { return }
        typingResetTasks[conversationId]?.cancel()
        typingResetTasks.removeValue(forKey: conversationId)
        if !started {
            typingConversations.remove(conversationId)
            return
        }
        typingConversations.insert(conversationId)
        // Self-heal if the "stopped" frame is lost (ephemeral, never queued).
        typingResetTasks[conversationId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.typingConversations.remove(conversationId)
            self?.typingResetTasks.removeValue(forKey: conversationId)
        }
    }

    private func clearPeerTyping(for conversationId: String) {
        typingResetTasks[conversationId]?.cancel()
        typingResetTasks.removeValue(forKey: conversationId)
        typingConversations.remove(conversationId)
    }

    private func existingConversation(withPeer account: String) -> String? {
        try? storage.database.query(
            "SELECT id FROM conversations WHERE peer_account = ?", [.text(account)]
        ).first?.first?.string
    }

    // MARK: - Peer device bookkeeping (encrypted kv table)

    private struct PeerDevice: Codable {
        let id: UInt32
        let mailboxId: String?
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

    // MARK: - Share Extension bridge

    // Writes an unencrypted conversation list to App Group storage so the
    // Share Extension can display a conversation picker without the encryption keys.
    private func updateShareConversationList() {
        let summaries = conversations.filter { !$0.archived }.map { conv -> ShareConversationSummary in
            let name: String
            if let gid = conv.groupId {
                name = displayName(forAccount: gid)
            } else {
                name = displayName(forAccount: conv.peerAccount)
            }
            return ShareConversationSummary(
                id: conv.id,
                displayName: name,
                initials: ShareBridge.makeInitials(name),
                isGroup: conv.groupId != nil,
                peerAccount: conv.peerAccount
            )
        }
        ShareBridge.writeConversations(summaries)
        for conv in conversations {
            if let data = peerAvatarData(forAccount: conv.peerAccount) {
                ShareBridge.writeAvatar(data, forConversationId: conv.id)
            }
        }
    }

    // Called when the app is foregrounded (or opened via relay://pending-share).
    // Reads a PendingShare written by the Share Extension and sends it.
    // Returns the conversationId so the caller can navigate there.
    func processPendingShare() async -> String? {
        guard let share = ShareBridge.readAndClearPendingShare() else { return nil }
        let conversationId = share.conversationId
        if let text = share.text, !text.isEmpty {
            await sendMessage(text, in: conversationId)
        } else if let imageData = share.imageData {
            let ct = mimeType(for: share.imageUTI ?? "public.jpeg")
            let attachment = PendingAttachment(
                data: imageData, contentType: ct, filename: nil, width: 0, height: 0
            )
            await sendMessage("", in: conversationId, attachments: [attachment])
        } else if let fileData = share.fileData, let name = share.filename {
            let ct = UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            let attachment = PendingAttachment(
                data: fileData, contentType: ct, filename: name, width: 0, height: 0
            )
            await sendMessage("", in: conversationId, attachments: [attachment])
        }
        return conversationId
    }

    private func mimeType(for uti: String) -> String {
        UTType(uti)?.preferredMIMEType ?? "image/jpeg"
    }

    // Donate an INSendMessageIntent interaction so iOS learns which contacts the
    // user messages via Relay and can show them as suggestions in the share sheet.
    private func donateInteraction(peerAccount account: String, conversationId: String) {
        let name = displayName(forAccount: account)
        let handle = INPersonHandle(value: account, type: .unknown)
        let avatarImage = peerAvatarData(forAccount: account).flatMap { INImage(imageData: $0) }
        let person = INPerson(
            personHandle: handle,
            nameComponents: nil,
            displayName: name,
            image: avatarImage,
            contactIdentifier: nil,
            customIdentifier: account
        )
        let intent = INSendMessageIntent(
            recipients: [person],
            outgoingMessageType: .outgoingMessageText,
            content: nil,
            speakableGroupName: nil,
            conversationIdentifier: conversationId,
            serviceName: "Relay",
            sender: nil,
            attachments: nil
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing
        interaction.donate { _ in }
    }

    // MARK: - View state refresh

    private func peerAccount(for conversationId: String) throws -> String? {
        try storage.database.query(
            "SELECT peer_account FROM conversations WHERE id = ?", [.text(conversationId)]
        ).first?.first?.string
    }

    private func refreshConversations() {
        // Suppress per-envelope refreshes during the initial queue drain; the
        // connection loop fires one batch refresh at queueDrained instead.
        guard !isDrainingQueue else { return }
        // Coalesce rapid-fire calls into one deferred update so a burst of
        // envelopes doesn't trigger a re-render storm. The DB query runs on a
        // background thread to keep the main thread free.
        guard !conversationsRefreshScheduled else { return }
        conversationsRefreshScheduled = true
        conversationsRefreshVersion &+= 1
        let version = conversationsRefreshVersion
        let messageStore = storage.messages
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try messageStore.conversations() }
            let unread = (try? result.get())?.reduce(0) { $0 + $1.unreadCount } ?? 0
            // Build lightweight Spotlight inputs on the main actor (cheap lookups
            // + cached avatar bytes), then index off-main so the image decode
            // doesn't hitch the UI.
            let indexItems: [SpotlightIndexer.IndexItem] = await MainActor.run { [weak self] in
                guard let self, self.conversationsRefreshVersion == version else { return [] }
                self.conversationsRefreshScheduled = false
                // If the DB query threw, leave conversations unchanged so
                // synchronously-injected entries (e.g. Note to Self) stay visible.
                guard case .success(let convs) = result else { return [] }
                self.conversations = convs
                self.updateShareConversationList()
                return convs.map { conv in
                    let account = conv.groupId ?? conv.peerAccount
                    let name = conv.groupId.map { self.displayName(forAccount: $0) }
                        ?? self.displayName(forAccount: conv.peerAccount)
                    return SpotlightIndexer.IndexItem(
                        id: conv.id, name: name,
                        avatarData: self.peerAvatarData(forAccount: account)
                    )
                }
            }
            if !indexItems.isEmpty { SpotlightIndexer.index(indexItems) }
            try? await UNUserNotificationCenter.current().setBadgeCount(unread)
            ShareBridge.writeUnreadCount(unread)
        }
    }

    private func refreshActiveMessages(ifShowing conversationId: String) {
        guard activeConversationId == conversationId else { return }
        let messageStore = storage.messages
        Task.detached(priority: .userInitiated) { [weak self] in
            let msgs = (try? messageStore.messages(in: conversationId)) ?? []
            await MainActor.run { [weak self] in
                guard let self, self.activeConversationId == conversationId else { return }
                self.activeMessages = msgs
                self.messagesLoadedConversationId = conversationId
            }
        }
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
            ).first?.first?.data.flatMap { UInt32(String(bytes: $0, encoding: .utf8) ?? "") } ?? 1
            let next = current + UInt32(count)
            try database.run(
                "INSERT OR REPLACE INTO kv (key, value) VALUES ('next-prekey-id', ?)",
                [.blob(Data("\(next)".utf8))]
            )
            return current..<next
        }
    }
}
