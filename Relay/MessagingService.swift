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

/// A labelled profile link (e.g. "Website" → https://…), edited locally and
/// distributed E2EE inside ProfileUpdate. Persisted as JSON (id is not encoded).
/// `nonisolated` so Codable synthesis stays off the app's MainActor default.
nonisolated struct ProfileLink: Codable, Hashable, Identifiable {
    var id = UUID()
    var label: String = ""
    var url: String = ""
    enum CodingKeys: String, CodingKey { case label, url }
}

enum MessagingError: LocalizedError {
    case attachmentTooLarge

    var errorDescription: String? {
        switch self {
        case .attachmentTooLarge: return "Attachment exceeds the 25 MB size limit."
        }
    }
}

enum GroupError: LocalizedError {
    case notFound
    case notAdmin

    var errorDescription: String? {
        switch self {
        case .notFound: return "That group no longer exists on this device."
        case .notAdmin: return "Only group admins can make this change."
        }
    }
}

/// The plaintext an encrypted group-invite blob decrypts to. Everything the
/// joiner needs to bootstrap the group locally and prove they held the link.
private struct GroupInvitePayload: Codable {
    let groupId: String
    let name: String
    let members: [String]
    let distributionId: String
    let inviteKey: Data
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    init?(base64URLEncoded s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
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

    let storage: SecureStore
    private let keychain: KeychainSecureStore
    private let engine: CryptoEngine
    private let processor: EnvelopeProcessor
    private let api: RelayAPIClient
    private let maintainer = PreKeyMaintainer()
    private let attachmentStore = AttachmentBlobStore(appGroupId: AppModel.appGroupId)
    private let allocator: KVPreKeyIdAllocator
    private var socket: RelayWebSocket?
    private var connectionTask: Task<Void, Never>?
    /// Polls the queue over HTTP/3 REST when the live WebSocket can't connect
    /// (congested networks). QUIC fallback for receiving; WS stays primary.
    private var pollTask: Task<Void, Never>?
    /// Whether the live WebSocket is currently up and draining. Distinct from the
    /// UI `connectionState`, which flips to `.connected` as soon as the server is
    /// reachable over QUIC (so the "connecting" spinner clears on congested
    /// networks even before/without the TCP socket). Gates the poll fallback.
    private var socketLive = false
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
        self.api = RelayAPIClient(baseURL: serverURL, credentials: credentials, session: session,
                                  signer: DeviceAuthSigner(keychain: keychain))
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

    /// Runs once per launch: re-publishes a fresh signed prekey so the relay's
    /// bundle always matches this device's local key store (heals a desync left
    /// by a reinstall that wiped local keys while the server kept the old ones).
    private var didRepublishKeysThisLaunch = false

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

    private var didSweepInterruptedSends = false

    func start() {
        guard connectionTask == nil else { return }
        if !didSweepInterruptedSends {
            // Only on the first start of this process: nothing can be mid-send
            // yet, so anything still "sending" was interrupted by a kill.
            didSweepInterruptedSends = true
            failInterruptedSends()
        }
        connectionTask = Task { await runConnectionLoop() }
        pollTask = Task { [weak self] in await self?.runQueuePollLoop() }
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
        pollTask?.cancel()
        pollTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        expireTask?.cancel()
        expireTask = nil
        // Reflect that nothing is running, so a background refresh knows to
        // start() the service again.
        connectionState = .disconnected
        socketLive = false
        isDrainingQueue = false
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
            if connectionState != .connected { connectionState = .connecting }
            socketLive = false
            do {
                // QUIC preflight: this REST call races HTTP/3, so it succeeds on
                // congested networks where the TCP WebSocket can't. Once it does,
                // the app is usable (send over sealed/HTTP-3, receive via the poll
                // loop) — so mark connected immediately instead of leaving the
                // "connecting" spinner up until the socket finally connects.
                _ = try await api.listDevices()
                authenticationExpired = false
                connectionState = .connected
                isDrainingQueue = false
                // Warm the sealed-sender delivery cert so the first send doesn't
                // pay for fetching it (cached ~7 days).
                Task { _ = try? await self.senderCertificate() }
            } catch RelayAPIError.http(let status, _) where status == 401 {
                log.warning("relay credentials expired; stopping reconnect loop")
                authenticationExpired = true
                isDrainingQueue = false
                connectionState = .disconnected
                connectionTask = nil
                return
            } catch {
                log.warning("relay auth/connectivity preflight failed: \(PrivacyRedactor.localizedError(error))")
                connectionState = .connecting
            }
            // Apply group/profile changes the notification extension stored
            // while we were backgrounded, before newer queued envelopes land.
            await drainPendingControlMessages(sendReceipts: false)
            let socket = RelayWebSocket(baseURL: serverURL, credentials: credentials, session: session)
            self.socket = socket
            for await event in await socket.connect() {
                switch event {
                case .queueDrained:
                    socketLive = true
                    isDrainingQueue = false
                    connectionState = .connected
                    backoffSeconds = 1.0
                    // One batch refresh after draining all queued messages.
                    refreshConversations()
                    // Now the socket is live, also send the delivery receipts
                    // the extension deferred.
                    await drainPendingControlMessages()
                    if !didRepublishKeysThisLaunch {
                        didRepublishKeysThisLaunch = true
                        do {
                            try await maintainer.republishSignedPreKey(api: api, engine: engine, allocator: allocator)
                        } catch {
                            log.warning("signed prekey republish failed: \(PrivacyRedactor.error(error))")
                        }
                    }
                    do {
                        try await maintainer.replenishIfNeeded(api: api, engine: engine, allocator: allocator)
                    } catch {
                        log.warning("prekey replenishment failed: \(PrivacyRedactor.error(error))")
                    }
                    await rotateMailboxIfNeeded()
                    await ensureNoteToSelf()
                    ensureRelayAccount()
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
            socketLive = false
            isDrainingQueue = false
            // Don't force `.disconnected` here: if the server is still reachable
            // over QUIC we stay usable via the poll loop, and the next iteration's
            // preflight re-confirms reachability (flipping to .connecting only if
            // it actually fails).
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(backoffSeconds))
            backoffSeconds = min(backoffSeconds * 2, 30)
        }
    }

    // MARK: - Incoming pipeline

    /// Periodically pulls queued envelopes over HTTP/3 REST while the live
    /// WebSocket isn't connected (e.g. a congested stadium network where TCP
    /// can't establish). The WebSocket stays the primary, low-latency path;
    /// dedup by envelope id makes any overlap harmless.
    private func runQueuePollLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            // Poll whenever the live socket isn't actually delivering, regardless
            // of the UI connection state (which may show "connected" via QUIC).
            guard !socketLive else { continue }
            guard let envelopes = try? await api.fetchQueue() else { continue }
            for envelope in envelopes {
                await handleEnvelope(envelope)
            }
        }
    }

    /// Acks a processed envelope over the WebSocket when it's live, else over
    /// HTTP/3 REST (so poll-fetched envelopes are dequeued too).
    private func ackEnvelope(_ id: String) async {
        if socketLive, let socket {
            try? await socket.ack(envelopeId: id)
        } else {
            try? await api.ackMessage(envelopeId: id)
        }
    }

    /// Tail of the envelope-processing chain. Both the WebSocket loop and the
    /// REST poll loop deliver envelopes; each `handleEnvelope` call waits for
    /// the previous one, so ratchet state for a sender is only ever advanced by
    /// one decrypt at a time even when the two loops overlap.
    private var envelopeChain: Task<Void, Never>?

    private func handleEnvelope(_ envelope: IncomingEnvelope) async {
        let previous = envelopeChain
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.processEnvelope(envelope)
        }
        envelopeChain = task
        await task.value
    }

    private func processEnvelope(_ envelope: IncomingEnvelope) async {
        // Ack unconditionally once processing finishes: an envelope that
        // fails to decrypt would otherwise redeliver forever. Dedup and
        // ratchet state make retrying it pointless anyway.
        defer {
            Task { await self.ackEnvelope(envelope.id) }
        }
        // Blocked senders are still decrypted (so the ratchet stays in step)
        // and then dropped by `process(_:blockedAccounts:)`.
        do {
            // Run crypto + DB write off the main thread. Serialization is
            // maintained by `handleEnvelope`'s chain, so ratchet state advances
            // one message at a time even though the work runs on a bg thread.
            let proc = processor
            let blocked = blockedAccounts
            let result = try await Task.detached(priority: .userInitiated) {
                try proc.process(envelope, blockedAccounts: blocked)
            }.value

            if let timestamp = result.sideEffects.deliveryReceiptTimestamp {
                let groupId = result.conversationId.flatMap { group(for: $0)?.id }
                // Sealed envelopes carry no sender on the outside — receipt the
                // identity authenticated by decryption.
                await sendReceipt(.delivery, timestamps: [timestamp], toPeer: result.peerAccount ?? envelope.senderAccount, groupId: groupId)
            }
            if let account = result.sideEffects.backfillUsernameForAccount,
               let conversationId = result.conversationId {
                backfillUsernameIfNeeded(conversationId: conversationId, account: account)
            }
            if let typingStarted = result.typingStarted {
                applyPeerTyping(started: typingStarted, peerAccount: result.peerAccount,
                                groupConversationId: result.conversationId)
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
                // Read the body of *this* envelope — `activeMessages` is
                // refreshed asynchronously and still holds the previous message.
                if result.outcome == .stored, let body = result.notification?.body {
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
                await handleGroupUpdate(groupUpdate, authenticatedSender: result.peerAccount)
            }
            if let profile = result.profile {
                await applyPeerProfile(profile)
            }
            if let callInfo = result.callInfo {
                await onCallMessage?(callInfo)
            }
            if let shot = result.screenshotAlert {
                let name = displayName(forAccount: shot.senderAccount)
                insertSystemLine("\(name) took a screenshot", conversationId: shot.conversationId)
            }
            if let upd = result.screenSecurityUpdate {
                try? storage.messages.setConversationPeerScreenSecurity(upd.conversationId, enabled: upd.enabled)
                refreshConversations()
            }
        } catch {
            log.error("failed to process encrypted envelope: \(PrivacyRedactor.error(error))")
            handlePossiblePreKeyDesync(error)
        }
    }

    /// A `PreKeySignalMessage` that references a one-time (or signed/Kyber)
    /// prekey the local store no longer holds means the relay is advertising a
    /// bundle we can't honour — the pool is desynced (typically an app reinstall
    /// that wiped local keys while the relay kept the old publication). The
    /// envelope itself is unrecoverable (already acked+dropped), but we heal the
    /// published pool so future sessions succeed instead of silently failing.
    private var didHealPreKeyPoolThisLaunch = false
    private static let preKeyDesyncCountKey = "prekey-desync-drop-count"

    private func handlePossiblePreKeyDesync(_ error: Error) {
        guard case StorageError.recordNotFound(let what) = error,
              what.contains("prekey") else { return }
        // Count it for diagnostics regardless of whether we heal this launch.
        incrementPreKeyDesyncCount()
        log.error("prekey pool desync detected (\(what, privacy: .public)); scheduling replace-publish")
        guard !didHealPreKeyPoolThisLaunch else { return }
        didHealPreKeyPoolThisLaunch = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await maintainer.replacePublishedPool(api: api, engine: engine, allocator: allocator)
                log.info("prekey pool replace-publish completed after desync")
            } catch {
                // Let a later desync retry (next launch) if this attempt failed.
                self.didHealPreKeyPoolThisLaunch = false
                log.error("prekey pool replace-publish failed: \(PrivacyRedactor.error(error))")
            }
        }
    }

    private func incrementPreKeyDesyncCount() {
        let current = preKeyDesyncDropCount
        try? storage.database.run(
            "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
            [.text(Self.preKeyDesyncCountKey), .blob(Data("\(current + 1)".utf8))]
        )
    }

    /// Number of envelopes dropped due to a prekey-pool desync (0 = none seen).
    /// Surfaced quietly in Settings diagnostics only when non-zero.
    var preKeyDesyncDropCount: Int {
        guard let data = try? storage.database.query(
            "SELECT value FROM kv WHERE key = ?", [.text(Self.preKeyDesyncCountKey)]
        ).first?.first?.data, let s = String(data: data, encoding: .utf8), let n = Int(s) else {
            return 0
        }
        return n
    }

    // MARK: - Blinded discovery

    /// Resolves a username to its account id without revealing the username to the
    /// relay: blind → server OPRF eval → unblind → token → resolve. Throws
    /// `RelayAPIError.http(404,…)` when no such user exists.
    /// Blinded discovery is unavailable on the server (OPRF key not configured).
    /// We deliberately do NOT fall back to the plaintext `by-username` lookup —
    /// that would leak the looked-up username to the relay, silently downgrading
    /// the privacy guarantee. Surface a clear error instead.
    enum DiscoveryError: LocalizedError {
        case unavailable
        var errorDescription: String? {
            "Private contact discovery isn’t available on this server right now. Please try again later."
        }
    }

    func resolveAccount(username: String) async throws -> String {
        guard let blinded = BlindedDiscovery.blind(username) else {
            throw RelayAPIError.malformedResponse
        }
        let evaluated: [Data]
        do {
            evaluated = try await api.directoryEvaluate(blinded: [blinded.element])
        } catch RelayAPIError.http(status: 503, _) {
            throw DiscoveryError.unavailable
        }
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
            let evaluated: [Data]
            do {
                evaluated = try await api.directoryEvaluate(blinded: chunkBlinds.map { $0.element })
            } catch RelayAPIError.http(status: 503, _) {
                throw DiscoveryError.unavailable
            }
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

    /// Sends a live-location update. Unlike `sendMessage`, this collapses into a
    /// single moving bubble (one row per sharer per conversation) instead of a
    /// new message every tick — both locally and, via the same stable key, on the
    /// recipient (see EnvelopeProcessor's live-location handling).
    func sendLiveLocation(_ body: String, in conversationId: String) async {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let locId = "liveloc:\(conversationId):\(credentials.accountId)"
        try? storage.messages.upsertLiveLocation(
            id: locId, conversationId: conversationId, isOutgoing: true,
            body: body, timestamp: timestamp, senderAccount: credentials.accountId
        )
        refreshConversations()
        refreshActiveMessages(ifShowing: conversationId)

        var content = Relay_Content_Content()
        content.text.body = body
        content.text.timestamp = timestamp
        content.senderAccountID = credentials.accountId
        content.senderDeviceID = credentials.deviceId
        do {
            if let group = group(for: conversationId) {
                content.groupID = group.id
                let data = try content.serializedData()
                for member in group.members where member != credentials.accountId {
                    try? await sendContent(data, toPeer: member, clientTimestamp: timestamp)
                }
            } else if let peer = try? peerAccount(for: conversationId),
                      peer != noteToSelfAccount, !isBlocked(peer) {
                try await sendContent(try content.serializedData(), toPeer: peer, clientTimestamp: timestamp)
            }
        } catch {
            log.warning("live location send failed: \(PrivacyRedactor.error(error))")
        }
    }

    func sendMessage(
        _ text: String,
        in conversationId: String,
        replyTo: QuotedMessage? = nil,
        attachments pending: [PendingAttachment] = []
    ) async {
        let group = try? groupForConversation(conversationId)
        if let group {
            // Announce-only: only admins may send.
            if group.isAnnounceOnly && !group.admins.contains(credentials.accountId) { return }
        } else {
            guard let peer = try? peerAccount(for: conversationId) else { return }
            // Blocked peer: the chat UI replaces the composer, so this is a guard.
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
        }

        // Store the message (with its sealed attachments cached locally) before
        // any network work, so a failed upload or send leaves a retryable
        // "Not Delivered" bubble instead of losing what the user typed.
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let localId = UUID().uuidString
        let stored: [StoredAttachment]
        do {
            stored = try sealLocally(pending)
            try storage.messages.insertMessage(
                id: localId, conversationId: conversationId, isOutgoing: true,
                body: text, timestamp: timestamp, status: .sending,
                replyTo: replyTo, attachments: stored,
                senderAccount: group == nil ? nil : credentials.accountId
            )
        } catch {
            log.error("send: could not store outgoing message: \(PrivacyRedactor.error(error))")
            sendErrorMessage = (error as? MessagingError)?.errorDescription
                ?? "This message couldn't be prepared. Please try again."
            return
        }
        refreshConversations()
        refreshActiveMessages(ifShowing: conversationId)

        // Opt-in cover-traffic delay: the message already shows locally as
        // "sending"; hold the wire transmission for a short random interval.
        await applySendJitter()
        await transmit(
            messageId: localId, conversationId: conversationId, body: text,
            timestamp: timestamp, replyTo: replyTo, attachments: stored
        )
    }

    /// Re-sends a message that previously failed. Keeps the original timestamp
    /// (receipts and quotes reference it), and for groups skips members an
    /// earlier attempt already reached.
    func retrySend(_ message: StoredMessage) async {
        guard message.isOutgoing, message.status == .failed else { return }
        try? storage.messages.updateStatus(messageId: message.id, status: .sending)
        refreshActiveMessages(ifShowing: message.conversationId)
        await transmit(
            messageId: message.id, conversationId: message.conversationId, body: message.body,
            timestamp: message.timestamp, replyTo: message.replyTo, attachments: message.attachments
        )
    }

    /// Set when a send can't even be queued (e.g. an oversized attachment);
    /// the chat shows it as an alert and clears it.
    var sendErrorMessage: String?

    /// Prefix for attachment ids that exist only on this device: sealed and
    /// cached, not yet uploaded. `uploadAttachments` swaps in the relay's id.
    private static let localAttachmentPrefix = "local-"

    /// Seals each pending attachment and caches the ciphertext under a local id.
    private func sealLocally(_ pending: [PendingAttachment]) throws -> [StoredAttachment] {
        // 25 MB plaintext limit — the server enforces 26 MB on the ciphertext
        // side, and AES-GCM overhead is negligible.
        let maxPlaintextBytes = 25 * 1024 * 1024
        return try pending.map { item in
            guard item.data.count <= maxPlaintextBytes else { throw MessagingError.attachmentTooLarge }
            let sealed = try AttachmentCipher.seal(item.data)
            let id = Self.localAttachmentPrefix + UUID().uuidString
            try attachmentStore.write(sealed.ciphertext, for: id)
            return StoredAttachment(
                id: id, key: sealed.key, digest: sealed.digest, contentType: item.contentType,
                size: Int64(sealed.ciphertext.count), filename: item.filename,
                width: item.width, height: item.height, isDownloaded: true
            )
        }
    }

    /// Uploads any attachments still held only locally, renaming the stored row
    /// and cache entry to the relay's blob id, and returns the wire pointers.
    /// Already-uploaded attachments (a retry after a later failure) are reused.
    private func uploadAttachments(_ attachments: [StoredAttachment]) async throws -> [Relay_Content_AttachmentPointer] {
        var pointers: [Relay_Content_AttachmentPointer] = []
        for attachment in attachments {
            var id = attachment.id
            if id.hasPrefix(Self.localAttachmentPrefix) {
                let ciphertext = try attachmentStore.read(id)
                let remoteId = try await api.uploadAttachment(ciphertext)
                try attachmentStore.write(ciphertext, for: remoteId)
                try storage.database.run(
                    "UPDATE attachments SET id = ? WHERE id = ?", [.text(remoteId), .text(id)]
                )
                attachmentStore.delete(id)
                id = remoteId
            }
            var pointer = Relay_Content_AttachmentPointer()
            pointer.id = id
            pointer.key = attachment.key
            pointer.digest = attachment.digest
            pointer.contentType = attachment.contentType
            pointer.size = UInt64(attachment.size)
            if let filename = attachment.filename { pointer.filename = filename }
            pointer.width = UInt32(attachment.width)
            pointer.height = UInt32(attachment.height)
            pointers.append(pointer)
        }
        return pointers
    }

    /// Uploads, encrypts and sends a stored outgoing message, then marks it
    /// sent — or failed, leaving it for `retrySend`.
    private func transmit(
        messageId: String, conversationId: String, body: String, timestamp: Int64,
        replyTo: QuotedMessage?, attachments: [StoredAttachment]
    ) async {
        do {
            var content = Relay_Content_Content()
            content.text.body = body
            content.text.timestamp = timestamp
            if let replyTo {
                content.text.quote.targetTimestamp = replyTo.targetTimestamp
                content.text.quote.author = replyTo.author
                content.text.quote.text = replyTo.text
            }
            content.text.attachments = try await uploadAttachments(attachments)
            content.senderAccountID = credentials.accountId
            content.senderDeviceID = credentials.deviceId
            let disappearSecs = conversations.first(where: { $0.id == conversationId })?.disappearingSeconds ?? 0
            if disappearSecs > 0 { content.expiresAfterMs = disappearSecs * 1000 }

            if let group = try? groupForConversation(conversationId) {
                content.groupID = group.id
                try await transmitToGroup(content, group: group, messageId: messageId, timestamp: timestamp)
                try storage.messages.updateStatus(messageId: messageId, status: .sent)
                // Mirror to our own other devices (the fan-out excludes our
                // account) so the group thread stays in sync across devices.
                await sendSyncToOwnDevices(content: content, peer: group.id, timestamp: timestamp)
            } else {
                guard let peer = try peerAccount(for: conversationId) else {
                    throw GroupError.notFound
                }
                // Ensure profile is current before sending (no-op if up to date).
                Task { await sendMyProfileIfNeeded(toPeer: peer) }
                try await sendContent(try content.serializedData(), toPeer: peer, clientTimestamp: timestamp)
                try storage.messages.updateStatus(messageId: messageId, status: .sent)
                donateInteraction(peerAccount: peer, conversationId: conversationId)
                // Send a sync copy to own other devices so they show this as sent.
                await sendSyncToOwnDevices(content: content, peer: peer, timestamp: timestamp)
            }
        } catch {
            log.error("send failed: \(PrivacyRedactor.error(error))")
            try? storage.messages.updateStatus(messageId: messageId, status: .failed)
            if let safetyError = error as? SafetyNumberChangedError {
                noteBlockedSafetyWarning(peer: safetyError.peer)
            }
        }
        refreshConversations()
        refreshActiveMessages(ifShowing: conversationId)
    }

    /// Marks outgoing messages left in "sending" by a previous run (the app was
    /// killed mid-send) as failed, so they show Retry instead of a clock forever.
    private func failInterruptedSends() {
        try? storage.database.run(
            "UPDATE messages SET status = ? WHERE is_outgoing = 1 AND status = ?",
            [.text(MessageStatus.failed.rawValue), .text(MessageStatus.sending.rawValue)]
        )
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
        } catch {
            log.warning("self-sync: resolve own devices failed: \(PrivacyRedactor.error(error))")
            return
        }
        guard !devices.isEmpty else {
            log.debug("self-sync: no other own devices to sync to")
            return
        }
        do {
            let payloads = try buildMailboxPayloads(padded, forPeer: credentials.accountId, devices: devices)
            let outcome = try await sendMailboxPayloads(payloads, clientTimestamp: timestamp)
            log.debug("self-sync: sent to \(devices.count) own device(s), outcome \(String(describing: outcome))")
        } catch {
            log.warning("self-sync: send failed: \(PrivacyRedactor.error(error))")
        }
    }

    // MARK: - Groups

    /// Sentinel sender for locally-inserted group system lines.
    static let systemSender = "__system__"
    /// The peer account for "Note to Self" is the user's own account — messages
    /// are sent to yourself via the server so they go through the normal E2EE path.
    var noteToSelfAccount: String { credentials.accountId }

    /// The reserved peer id + username for the official, read-only "Relay"
    /// system chat that surfaces account notices (device linked, etc.). The
    /// `relay` username is reserved server-side so no user can impersonate it.
    static let relayOfficialAccount = "relay.official"
    static let relayOfficialUsername = "relay"
    /// Instance accessor mirroring `noteToSelfAccount`, for views.
    var relayOfficialAccount: String { Self.relayOfficialAccount }

    /// The stored group backing a conversation (nil for 1:1), for the UI.
    func group(for conversationId: String) -> StoredGroup? {
        try? groupForConversation(conversationId)
    }

    /// Groups shared with a peer — computed locally from stored rosters, shown
    /// on their contact card. Returns (conversationId, group name).
    func mutualGroups(with account: String) -> [(id: String, name: String)] {
        conversations.compactMap { conv in
            guard conv.isGroup,
                  let g = group(for: conv.id),
                  g.members.contains(account) else { return nil }
            return (conv.id, g.name)
        }
    }

    /// A human name for an account, in precedence order: "You" for self, a
    /// user-set nickname, the known username, else a short account prefix.
    /// Result is cached in memory to avoid DB reads during render.
    func displayName(forAccount account: String) -> String {
        if account == Self.relayOfficialAccount { return "Relay" }
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

    /// This user's short status line and longer bio, distributed to peers over
    /// the E2EE profile channel. Stored locally in UserDefaults.
    var myStatus: String { UserDefaults.standard.string(forKey: "my.profile.status") ?? "" }
    var myBio: String { UserDefaults.standard.string(forKey: "my.profile.bio") ?? "" }

    /// This user's labelled profile links, distributed E2EE inside ProfileUpdate.
    var myLinks: [ProfileLink] {
        Self.decodeLinks(UserDefaults.standard.string(forKey: "my.profile.links"))
    }

    /// Persists status/bio/links and, if any changed, bumps the profile revision
    /// so the update is redistributed to every peer.
    func setMyProfileText(status: String, bio: String, links: [ProfileLink]) {
        let s = status.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = links
            .map { ProfileLink(label: $0.label.trimmingCharacters(in: .whitespacesAndNewlines),
                               url: $0.url.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.label.isEmpty || !$0.url.isEmpty }
        let newLinksJSON = Self.encodeLinks(cleaned)
        let oldLinksJSON = UserDefaults.standard.string(forKey: "my.profile.links") ?? ""
        guard s != myStatus || b != myBio || newLinksJSON != oldLinksJSON else { return }
        UserDefaults.standard.set(s, forKey: "my.profile.status")
        UserDefaults.standard.set(b, forKey: "my.profile.bio")
        UserDefaults.standard.set(newLinksJSON, forKey: "my.profile.links")
        bumpMyProfileRevision()
    }

    /// JSON <-> [ProfileLink] helpers (links persist as a JSON string both in
    /// UserDefaults for self and in the profiles table for peers).
    static func decodeLinks(_ json: String?) -> [ProfileLink] {
        guard let json, let data = json.data(using: .utf8),
              let links = try? JSONDecoder().decode([ProfileLink].self, from: data) else { return [] }
        return links
    }

    static func encodeLinks(_ links: [ProfileLink]) -> String {
        guard !links.isEmpty, let data = try? JSONEncoder().encode(links),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
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
        // Group members (flatten, deduplicate). group_state is keyed by group
        // id, not conversation id.
        let groupMembers: [String] = conversations
            .compactMap { $0.groupId }
            .compactMap { try? storage.messages.group(id: $0) }
            .flatMap { $0.members }
        let excluded: Set<String> = [credentials.accountId, relayOfficialAccount]
        let allPeers = Set(dmPeers + groupMembers)
            .filter { !excluded.contains($0) && !isBlocked($0) }
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
            content.profile.status = myStatus
            content.profile.bio = myBio
            content.profile.links = myLinks.map {
                var l = Relay_Content_ProfileLink()
                l.label = $0.label
                l.url = $0.url
                return l
            }
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
    func applyPeerProfile(_ profile: ProfileInfo) async {
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
            let linksJSON = Self.encodeLinks(
                profile.links.map { ProfileLink(label: $0.label, url: $0.url) })
            try storage.messages.upsertProfile(
                account: profile.account,
                displayName: profile.displayName.isEmpty ? nil : profile.displayName,
                avatarId: avatarId, avatarData: avatarData, revision: revisionToStore,
                status: profile.status.isEmpty ? nil : profile.status,
                bio: profile.bio.isEmpty ? nil : profile.bio,
                linksJSON: linksJSON.isEmpty ? nil : linksJSON
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
    /// A peer's self-set status line (from their E2EE profile). Empty if none.
    func peerStatus(forAccount account: String) -> String {
        if account == credentials.accountId { return myStatus }
        return ((try? storage.messages.peerProfile(account: account)) ?? nil)?.status ?? ""
    }

    /// A peer's self-set bio (from their E2EE profile). Empty if none.
    func peerBio(forAccount account: String) -> String {
        if account == credentials.accountId { return myBio }
        return ((try? storage.messages.peerProfile(account: account)) ?? nil)?.bio ?? ""
    }

    /// A peer's self-set profile links (from their E2EE profile). Empty if none.
    func peerLinks(forAccount account: String) -> [ProfileLink] {
        if account == credentials.accountId { return myLinks }
        let json = ((try? storage.messages.peerProfile(account: account)) ?? nil)?.linksJSON
        return Self.decodeLinks(json)
    }

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
        insertSystemLine(text, conversationId: conversationId)
    }

    /// Inserts a centered "system" line into any conversation (DM or group).
    func insertSystemLine(_ text: String, conversationId: String) {
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
    /// Local authorization: only admins may change group state. Legacy groups
    /// with no recorded admins are treated as open (every member authorized).
    private func requireGroupAdmin(_ group: StoredGroup) throws {
        guard group.admins.isEmpty || group.admins.contains(credentials.accountId) else {
            throw GroupError.notAdmin
        }
    }

    /// Creates a group entirely client-side: the id and sender-key epoch are
    /// generated locally and the roster is distributed E2E. The relay never
    /// learns the group exists, its name, or its membership.
    func createGroup(name: String, memberUsernames: [String]) async throws -> String {
        var members: [String] = [credentials.accountId]
        for username in memberUsernames {
            let account = try await resolveAccount(username: username)
            if !members.contains(account) { members.append(account) }
            try? await refreshSessions(withPeer: account) // need pairwise sessions for SKDM/control
        }
        let groupId = UUID().uuidString
        let distributionId = UUID().uuidString
        try storage.messages.upsertGroup(
            id: groupId, name: name, distributionId: distributionId, revision: 1,
            members: members, admins: [credentials.accountId]
        )
        refreshConversations()
        if let stored = try storage.messages.group(id: groupId) {
            try? await distributeSenderKeyIfNeeded(group: stored)
            await sendGroupUpdate(.create, group: stored, target: "")
        }
        insertSystemLine("You created \"\(name)\"", inGroup: groupId)
        await resolveUsernames(members)
        return try storage.messages.groupConversationId(groupId: groupId) ?? ""
    }

    func addGroupMember(username: String, toGroup groupId: String) async throws {
        let account = try await resolveAccount(username: username)
        try? await refreshSessions(withPeer: account)
        guard let existing = try storage.messages.group(id: groupId) else { throw GroupError.notFound }
        try requireGroupAdmin(existing)
        var members = existing.members
        if !members.contains(account) { members.append(account) }
        try storage.messages.upsertGroup(
            id: groupId, name: existing.name, distributionId: existing.distributionId,
            revision: existing.revision + 1, members: members, admins: existing.admins,
            isAnnounceOnly: existing.isAnnounceOnly
        )
        refreshConversations()
        if let stored = try storage.messages.group(id: groupId) {
            try? await distributeSenderKeyIfNeeded(group: stored) // reaches the new member
            await sendGroupUpdate(.add, group: stored, target: account)
        }
        insertSystemLine("You added \(username)", inGroup: groupId)
    }

    func removeGroupMember(_ account: String, fromGroup groupId: String) async throws {
        guard let existing = try storage.messages.group(id: groupId) else { throw GroupError.notFound }
        try requireGroupAdmin(existing)
        let members = existing.members.filter { $0 != account }
        // Rotate the sender-key epoch so the removed member can't read future
        // messages (was server-driven; now client-driven). A fresh distribution
        // id makes every remaining member mint a new sender key on next send.
        let newDistributionId = UUID().uuidString
        try storage.messages.upsertGroup(
            id: groupId, name: existing.name, distributionId: newDistributionId,
            revision: existing.revision + 1, members: members,
            admins: existing.admins.filter { $0 != account }, isAnnounceOnly: existing.isAnnounceOnly
        )
        refreshConversations()
        if let stored = try storage.messages.group(id: groupId) {
            try? await distributeSenderKeyIfNeeded(group: stored) // fresh epoch → redistribute to remaining
            await sendGroupUpdate(.remove, group: stored, target: account)
        }
        insertSystemLine("You removed \(displayName(forAccount: account))", inGroup: groupId)
    }

    func renameGroup(groupId: String, name: String) async throws {
        guard let existing = try storage.messages.group(id: groupId) else { throw GroupError.notFound }
        try requireGroupAdmin(existing)
        try storage.messages.upsertGroup(
            id: groupId, name: name, distributionId: existing.distributionId,
            revision: existing.revision + 1, members: existing.members,
            admins: existing.admins, isAnnounceOnly: existing.isAnnounceOnly
        )
        refreshConversations()
        if let stored = try storage.messages.group(id: groupId) {
            var update = Relay_Content_GroupUpdate()
            update.action = .rename
            update.name = name
            await sendGroupUpdateCustom(update, group: stored)
        }
        insertSystemLine("You renamed the group to \"\(name)\"", inGroup: groupId)
    }

    func setGroupDescription(_ description: String, groupId: String) async throws {
        guard let existing = try storage.messages.group(id: groupId) else { throw GroupError.notFound }
        try requireGroupAdmin(existing)
        try storage.messages.setGroupDescription(id: groupId, description: description)
        refreshConversations()
        if let stored = try storage.messages.group(id: groupId) {
            var update = Relay_Content_GroupUpdate()
            update.action = .describe
            update.description_p = description
            await sendGroupUpdateCustom(update, group: stored)
        }
        insertSystemLine("You updated the group description", inGroup: groupId)
    }

    func setGroupAvatar(_ data: Data, groupId: String) async throws {
        guard let existing = try storage.messages.group(id: groupId) else { throw GroupError.notFound }
        try requireGroupAdmin(existing)
        // The avatar bytes ride the same encrypted-attachment path as media, so
        // the relay only ever stores opaque ciphertext.
        let sealed = try AttachmentCipher.seal(data)
        let blobId = try await api.uploadAttachment(sealed.ciphertext)
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

    /// Mints an encrypted invite link. The relay stores only opaque ciphertext;
    /// the decrypt key rides the URL fragment, and the embedded invite capability
    /// lets members verify a joiner actually held the link.
    func createGroupInviteLink(groupId: String) async throws -> String {
        guard let group = try storage.messages.group(id: groupId) else { throw GroupError.notFound }
        try requireGroupAdmin(group)
        // Establish the invite capability if this is the group's first link, and
        // push it to members (silently) so they can verify joins.
        if groupInviteKey(groupId) == nil {
            var key = Data(count: 32)
            key.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
            setGroupInviteKey(groupId, key)
            var announce = Relay_Content_GroupUpdate()
            announce.action = .unspecified // silent: carries only the invite key
            await sendGroupUpdateCustom(announce, group: group)
        }
        guard let inviteKey = groupInviteKey(groupId) else { throw GroupError.notFound }
        let payload = GroupInvitePayload(
            groupId: groupId, name: group.name, members: group.members,
            distributionId: group.distributionId, inviteKey: inviteKey
        )
        let sealed = try AttachmentCipher.seal(try JSONEncoder().encode(payload))
        let (token, _) = try await api.createEncryptedGroupInvite(blob: sealed.ciphertext)
        let fragment = (sealed.key + sealed.digest).base64URLEncodedString()
        return "https://relaymsg.app/g/\(token)#\(fragment)"
    }

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

    /// Primary side of reversed linking: provisions a device that displayed a
    /// linking QR. Creates the device's server-side row, then seals the account's
    /// shared identity key + the new device's credentials to its ephemeral public
    /// key and deposits the ciphertext on the relay for it to fetch. The identity
    /// private key is encrypted end-to-end here and is never logged.
    func provisionScannedDevice(
        sessionId: String,
        ephemeralPublicKey: Data,
        newDeviceServerURL: String,
        deviceName: String?,
        syncConversations: Bool,
        syncHistory: Bool
    ) async throws {
        // The new device polls the relay it created the session on; it must be
        // the same relay we're authenticated against, or the blob never arrives.
        guard newDeviceServerURL == serverURL.absoluteString else {
            throw LinkingError.serverMismatch
        }
        // User-presence gate: adding a device shares this account's identity, so
        // require an explicit biometric confirmation before sealing anything.
        guard await BiometricGate.authenticate(reason: "Confirm linking a new device to your Relay account.") else {
            throw LinkingError.notAuthorized
        }
        let password = Self.newDevicePassword()
        let authorization = try await deviceMutationAuthorization(action: "link", targetDeviceId: 0, password: password)
        let deviceId = try await api.linkDevice(password: password, deviceName: deviceName, authorization: authorization)

        // The account identity key pair — shared with the new device so every
        // device of the account presents the same identity.
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

        // Authenticate the payload: sign a transcript binding this session, the
        // new device's ephemeral key, and the issued credentials with the
        // account identity key, so the new device can prove it came from a
        // legitimate primary (not a replayed/substituted blob).
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

        // Transparency: record the new device in the official Relay chat so a
        // silent addition can't go unnoticed.
        postRelayNotice("A new device (device \(deviceId)) was linked to your account. If this wasn't you, unlink it in Settings → Linked Devices and change your recovery details.")
    }

    /// A fresh random device password (32 bytes, URL-safe base64). Bound into the
    /// device-mutation signature and delivered to the new device inside the
    /// encrypted provisioning payload.
    static func newDevicePassword() -> String {
        var b = Data(count: 32)
        b.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
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

    // MARK: - Encrypted backup payload (for iCloud recovery)

    /// A full, portable snapshot of local chat state. Encrypted by
    /// CloudBackupManager before it ever leaves the device.
    struct BackupSnapshot: Codable {
        struct Message: Codable {
            let id: String
            let body: String
            let timestamp: Int64
            let isOutgoing: Bool
            let status: String
            let senderAccount: String?
            let replyTimestamp: Int64?
            let replyAuthor: String?
            let replyText: String?
        }
        struct Conversation: Codable {
            let peerAccount: String
            let username: String?
            let groupId: String?
            let messages: [Message]
        }
        struct Group: Codable {
            let id: String
            let name: String
            let distributionId: String
            let revision: Int64
            let members: [String]
            let admins: [String]
            let isAnnounceOnly: Bool
        }
        var version: Int = 1
        var conversations: [Conversation]
        var groups: [Group]
    }

    /// Serializes all conversations, messages, and group state into a snapshot.
    func exportBackupSnapshot() -> BackupSnapshot {
        var convs: [BackupSnapshot.Conversation] = []
        var groups: [BackupSnapshot.Group] = []
        for conv in (try? storage.messages.conversations()) ?? [] {
            let msgs = ((try? storage.messages.messages(in: conv.id, limit: 100_000)) ?? []).map { m in
                BackupSnapshot.Message(
                    id: m.id, body: m.body, timestamp: m.timestamp,
                    isOutgoing: m.isOutgoing, status: m.status.rawValue, senderAccount: m.senderAccount,
                    replyTimestamp: m.replyTo?.targetTimestamp,
                    replyAuthor: m.replyTo?.author, replyText: m.replyTo?.text
                )
            }
            convs.append(BackupSnapshot.Conversation(
                peerAccount: conv.peerAccount, username: conv.peerUsername,
                groupId: conv.groupId, messages: msgs
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

    /// Imports a decrypted snapshot into local storage (idempotent — existing
    /// message ids are skipped). Used when restoring on a fresh device.
    func importBackupSnapshot(_ snapshot: BackupSnapshot) {
        for g in snapshot.groups {
            try? storage.messages.upsertGroup(
                id: g.id, name: g.name, distributionId: g.distributionId, revision: g.revision,
                members: g.members, admins: g.admins, isAnnounceOnly: g.isAnnounceOnly
            )
        }
        for c in snapshot.conversations {
            let convId: String
            if let gid = c.groupId {
                convId = (try? storage.messages.groupConversationId(groupId: gid))
                    ?? (try? storage.messages.conversation(withPeer: gid, username: c.username)) ?? ""
            } else {
                convId = (try? storage.messages.conversation(withPeer: c.peerAccount, username: c.username)) ?? ""
            }
            guard !convId.isEmpty else { continue }
            for m in c.messages {
                let replyTo = m.replyTimestamp.map {
                    QuotedMessage(targetTimestamp: $0, author: m.replyAuthor ?? "", text: m.replyText ?? "")
                }
                _ = try? storage.messages.insertMessage(
                    id: m.id, conversationId: convId, isOutgoing: m.isOutgoing,
                    body: m.body, timestamp: m.timestamp,
                    status: MessageStatus(rawValue: m.status) ?? .received,
                    replyTo: replyTo, senderAccount: m.senderAccount
                )
            }
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
        postRelayNotice("Device \(deviceId) was unlinked from your account.")
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

    /// Redeems an encrypted invite: fetches the opaque blob, decrypts it with the
    /// fragment key, bootstraps the group locally, then announces our join to the
    /// members — echoing the invite capability so our (non-admin) self-add is
    /// accepted. `fragment` is the base64url key‖digest from the link's `#...`.
    func joinGroupByInvite(token: String, fragment: String) async throws -> String {
        guard let keyDigest = Data(base64URLEncoded: fragment), keyDigest.count == 64 else {
            throw RelayAPIError.malformedResponse
        }
        let blob = try await api.claimEncryptedGroupInvite(token: token)
        let json = try AttachmentCipher.open(
            blob, key: Data(keyDigest.prefix(32)), digest: Data(keyDigest.suffix(32))
        )
        let payload = try JSONDecoder().decode(GroupInvitePayload.self, from: json)

        var members = payload.members
        if !members.contains(credentials.accountId) { members.append(credentials.accountId) }
        setGroupInviteKey(payload.groupId, payload.inviteKey)
        try storage.messages.upsertGroup(
            id: payload.groupId, name: payload.name, distributionId: payload.distributionId,
            revision: 1, members: members, admins: []
        )
        refreshConversations()
        for member in payload.members where member != credentials.accountId {
            try? await refreshSessions(withPeer: member)
        }
        if let stored = try storage.messages.group(id: payload.groupId) {
            try? await distributeSenderKeyIfNeeded(group: stored)
            var join = Relay_Content_GroupUpdate()
            join.action = .add
            join.target = credentials.accountId
            await sendGroupUpdateCustom(join, group: stored) // carries the echoed invite key
        }
        insertSystemLine("You joined via invite link", inGroup: payload.groupId)
        await resolveUsernames(members)
        return try storage.messages.groupConversationId(groupId: payload.groupId) ?? ""
    }

    func leaveGroup(_ groupId: String) async throws {
        guard let existing = try storage.messages.group(id: groupId) else { throw GroupError.notFound }
        // Announce our departure to the remaining members over E2E (any member may
        // leave), then drop the group locally.
        let remaining = existing.members.filter { $0 != credentials.accountId }
        let announce = StoredGroup(
            id: existing.id, name: existing.name, distributionId: existing.distributionId,
            revision: existing.revision + 1, members: existing.members,
            admins: existing.admins, isAnnounceOnly: existing.isAnnounceOnly
        )
        await sendGroupUpdate(.leave, group: announce, target: credentials.accountId)
        try storage.messages.upsertGroup(
            id: groupId, name: existing.name, distributionId: existing.distributionId,
            revision: existing.revision + 1, members: remaining,
            admins: existing.admins.filter { $0 != credentials.accountId },
            isAnnounceOnly: existing.isAnnounceOnly
        )
        refreshConversations()
        insertSystemLine("You left", inGroup: groupId)
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

    /// Fans a group message out to every member. A member that fails doesn't
    /// stop the others; the members already reached are remembered (per
    /// message) so a retry only re-sends to the rest and nobody gets a duplicate.
    private func transmitToGroup(
        _ content: Relay_Content_Content, group: StoredGroup, messageId: String, timestamp: Int64
    ) async throws {
        // Sealed groups fan out as pairwise sealed messages, which don't use
        // sender keys — so skip SKDM distribution entirely.
        if !sealedSenderEnabled {
            try await distributeSenderKeyIfNeeded(group: group)
        }
        await distributeProfileToGroupMembersIfNeeded(group: group)

        let deliveredKey = "groupsent:\(messageId)"
        var delivered = Set(loadStringArray(deliveredKey))
        let targets = group.members.filter { $0 != credentials.accountId && !delivered.contains($0) }
        var firstError: Error?
        if sealedSenderEnabled {
            // Sealed groups: individual pairwise sealed messages. The group id
            // inside the encrypted content still routes each copy to the group
            // conversation, but the relay learns neither the sender nor that
            // these deliveries form one group send.
            let payload = try content.serializedData()
            for member in targets {
                do {
                    try await sendContent(payload, toPeer: member, clientTimestamp: timestamp)
                    delivered.insert(member)
                } catch {
                    firstError = firstError ?? error
                }
            }
        } else {
            // Encrypt once with our sender key, fan the same ciphertext out.
            guard let distributionId = UUID(uuidString: group.distributionId) else { throw GroupError.notFound }
            let sealed = try engine.groupEncrypt(try ContentPadding.pad(content.serializedData()), distributionId: distributionId)
            for member in targets {
                do {
                    try await sendEncrypted(sealed, toPeer: member, clientTimestamp: timestamp)
                    delivered.insert(member)
                } catch {
                    firstError = firstError ?? error
                }
            }
        }
        if let firstError {
            saveStringArray(deliveredKey, Array(delivered))
            throw firstError
        }
        try? storage.database.run("DELETE FROM kv WHERE key = ?", [.text(deliveredKey)])
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
        // Include the full roster, admin list, and current sender-key epoch so
        // recipients keep their local group state in sync without any server
        // round-trip (fully client-managed groups).
        u.members = group.members
        u.admins = group.admins
        u.distributionID = group.distributionId
        if let inviteKey = groupInviteKey(group.id) { u.inviteKey = inviteKey }
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
    /// Applies an incoming group change. `authenticatedSender` is the identity the
    /// messaging layer already verified sent this (sealed-sender certificate or
    /// ratchet), which we use as the source of truth for authorization — the
    /// encryption already proves who sent it, so no extra signature is needed.
    func handleGroupUpdate(_ info: GroupUpdateInfo, authenticatedSender: String?) async {
        let existing = try? storage.messages.group(id: info.groupId)

        // 1. The claimed `actor` must match who actually sent the (encrypted)
        //    message. A mismatch means a forged actor field — drop it.
        if let sender = authenticatedSender, !sender.isEmpty, !info.actor.isEmpty, info.actor != sender {
            log.warning("group update: actor != authenticated sender; dropping")
            return
        }
        let actor = (authenticatedSender.flatMap { $0.isEmpty ? nil : $0 }) ?? info.actor
        guard !actor.isEmpty else { return }

        // 2. Authorization. On first contact (no local state) we bootstrap by
        //    trusting the authenticated actor who is adding us. Otherwise only an
        //    admin may change group state; any member may remove themselves
        //    (leave); and a link-joiner may add *themselves* if they echo the
        //    group's current invite capability. Legacy groups with an empty admin
        //    list are treated as open.
        let isBootstrap = (existing == nil)
        let actorIsAdmin = existing.map { $0.admins.isEmpty || $0.admins.contains(actor) } ?? true
        let isSelfDeparture = (info.action == .leave || info.action == .remove) && info.target == actor
        let isValidSelfJoin = info.action == .add && info.target == actor
            && !info.inviteKey.isEmpty && groupInviteKey(info.groupId) == info.inviteKey
        guard isBootstrap || actorIsAdmin || isSelfDeparture || isValidSelfJoin else {
            log.warning("group update: \(String(describing: info.action)) from non-admin; dropping")
            return
        }

        // Persist/refresh the invite capability from authorized senders so we can
        // verify future link joins. Never from an unauthorized self-join echo.
        if !info.inviteKey.isEmpty, isBootstrap || actorIsAdmin {
            setGroupInviteKey(info.groupId, info.inviteKey)
        }
        // A silent capability broadcast (unspecified action) carries only the
        // invite key — nothing else to apply.
        if info.action == .unknown { return }

        // 3. We were removed by an admin — drop the group from our local roster so
        //    we stop sending to it.
        if info.action == .remove, info.target == credentials.accountId, let existing {
            do {
                try storage.messages.upsertGroup(
                    id: info.groupId, name: existing.name, distributionId: existing.distributionId,
                    revision: max(info.revision, existing.revision),
                    members: existing.members.filter { $0 != credentials.accountId },
                    admins: existing.admins
                )
                refreshConversations()
                if let line = systemLine(for: info) { insertSystemLine(line, inGroup: info.groupId) }
            } catch { log.warning("group remove(self) failed: \(PrivacyRedactor.error(error))") }
            return
        }

        // 4. Metadata-only actions carry their payload directly.
        switch info.action {
        case .describe:
            do {
                try storage.messages.setGroupDescription(id: info.groupId, description: info.description)
                refreshConversations()
                if let line = systemLine(for: info) { insertSystemLine(line, inGroup: info.groupId) }
            } catch { log.warning("group description update failed: \(PrivacyRedactor.error(error))") }
            return
        case .avatar where !info.avatarId.isEmpty:
            Task {
                do {
                    let ciphertext = try await api.downloadAttachment(id: info.avatarId)
                    let data = try AttachmentCipher.open(ciphertext, key: info.avatarKey, digest: info.avatarDigest)
                    try storage.messages.setGroupAvatar(id: info.groupId, avatarData: data)
                    refreshConversations()
                } catch { log.warning("group avatar download failed: \(PrivacyRedactor.error(error))") }
            }
            return
        case .promoteAdmin, .demoteAdmin:
            do {
                try storage.messages.setGroupAdmins(id: info.groupId, admins: info.admins)
                refreshConversations()
                if let line = systemLine(for: info) { insertSystemLine(line, inGroup: info.groupId) }
            } catch { log.warning("group admin update failed: \(PrivacyRedactor.error(error))") }
            return
        case .setAnnounceOnly:
            do {
                try storage.messages.setGroupAnnounceOnly(id: info.groupId, isAnnounceOnly: info.announceOnly)
                refreshConversations()
                if let line = systemLine(for: info) { insertSystemLine(line, inGroup: info.groupId) }
            } catch { log.warning("group announce-only update failed: \(PrivacyRedactor.error(error))") }
            return
        case .setScreenSecurity:
            do {
                try storage.messages.setGroupScreenSecurity(id: info.groupId, enabled: info.screenSecurity)
                refreshConversations()
                if let line = systemLine(for: info) { insertSystemLine(line, inGroup: info.groupId) }
            } catch { log.warning("group screen-security update failed: \(PrivacyRedactor.error(error))") }
            return
        default:
            break
        }

        // 5. Roster actions (create/add/remove/leave/rename).
        let newMembers: [String]
        let newAdmins: [String]
        let newName: String
        let distributionId: String
        if isValidSelfJoin && !isBootstrap && !actorIsAdmin, let existing {
            // A link-joiner: only ever ADD themselves. Never let a non-admin's
            // message overwrite the roster, admins, name, or epoch.
            newMembers = existing.members.contains(actor) ? existing.members : existing.members + [actor]
            newAdmins = existing.admins
            newName = existing.name
            distributionId = existing.distributionId
        } else {
            // Authorized admin / creator / bootstrap: trust the full lists (self-
            // healing), falling back to the delta when only a target is provided.
            var members = info.members.isEmpty ? (existing?.members ?? []) : info.members
            if info.members.isEmpty {
                switch info.action {
                case .add where !info.target.isEmpty:
                    if !members.contains(info.target) { members.append(info.target) }
                case .remove, .leave:
                    members.removeAll { $0 == info.target }
                default:
                    break
                }
            }
            newMembers = members
            newAdmins = info.admins.isEmpty ? (existing?.admins ?? [actor]) : info.admins
            newName = info.name.isEmpty ? (existing?.name ?? "") : info.name
            // Adopt a rotated epoch (e.g. after a removal) so our next send uses a
            // fresh sender key the removed member can't read.
            distributionId = !info.distributionId.isEmpty
                ? info.distributionId
                : (existing?.distributionId ?? UUID().uuidString)
        }
        do {
            try storage.messages.upsertGroup(
                id: info.groupId, name: newName, distributionId: distributionId,
                revision: max(info.revision, existing?.revision ?? 0),
                members: newMembers, admins: newAdmins
            )
            refreshConversations()
            if let convoId = try? storage.messages.groupConversationId(groupId: info.groupId) {
                refreshActiveMessages(ifShowing: convoId)
            }
            await resolveUsernames(newMembers)
            if let line = systemLine(for: info) { insertSystemLine(line, inGroup: info.groupId) }
            // Non-sealed groups use sender keys: give any newly-added members our
            // key, and mint a fresh one after an epoch rotation (removal).
            if !sealedSenderEnabled, newMembers.contains(credentials.accountId),
               let stored = try? storage.messages.group(id: info.groupId) {
                try? await distributeSenderKeyIfNeeded(group: stored)
            }
        } catch {
            log.warning("group update failed: \(PrivacyRedactor.error(error))")
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
        case .setScreenSecurity: return info.screenSecurity
            ? "\(actor) turned on screenshot protection"
            : "\(actor) turned off screenshot protection"
        case .unknown: return nil
        }
    }

    // MARK: - Admin management

    func promoteAdmin(in groupId: String, account: String) async throws {
        guard let existing = try storage.messages.group(id: groupId) else { throw GroupError.notFound }
        try requireGroupAdmin(existing)
        let admins = existing.admins.contains(account) ? existing.admins : existing.admins + [account]
        try storage.messages.setGroupAdmins(id: groupId, admins: admins)
        guard let grp = try? storage.messages.group(id: groupId) else { return }
        var update = Relay_Content_GroupUpdate()
        update.action = .promoteAdmin
        update.target = account
        update.admins = admins
        await sendGroupUpdateCustom(update, group: grp)
        insertSystemLine("\(displayName(forAccount: credentials.accountId)) made \(displayName(forAccount: account)) an admin", inGroup: groupId)
        refreshConversations()
    }

    func demoteAdmin(in groupId: String, account: String) async throws {
        guard let existing = try storage.messages.group(id: groupId) else { throw GroupError.notFound }
        try requireGroupAdmin(existing)
        let admins = existing.admins.filter { $0 != account }
        try storage.messages.setGroupAdmins(id: groupId, admins: admins)
        guard let grp = try? storage.messages.group(id: groupId) else { return }
        var update = Relay_Content_GroupUpdate()
        update.action = .demoteAdmin
        update.target = account
        update.admins = admins
        await sendGroupUpdateCustom(update, group: grp)
        insertSystemLine("\(displayName(forAccount: credentials.accountId)) removed \(displayName(forAccount: account)) as admin", inGroup: groupId)
        refreshConversations()
    }

    func setAnnounceOnly(_ enabled: Bool, in groupId: String) async throws {
        guard let existing = try storage.messages.group(id: groupId) else { throw GroupError.notFound }
        try requireGroupAdmin(existing)
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

    /// The group's invite capability (used to authorize link-based self-joins),
    /// stored in the encrypted kv table rather than a schema column.
    private func groupInviteKey(_ groupId: String) -> Data? {
        try? storage.database.query(
            "SELECT value FROM kv WHERE key = ?", [.text("ginvkey:\(groupId)")]
        ).first?.first?.data
    }

    private func setGroupInviteKey(_ groupId: String, _ key: Data) {
        try? storage.database.run(
            "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
            [.text("ginvkey:\(groupId)"), .blob(key)]
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

    func sendReceipt(
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
        if !ephemeral {
            try requireAcknowledgedIdentity(forPeer: account)
        }
        let payloadPlaintext = ephemeral ? plaintext : try ContentPadding.pad(plaintext)
        // Sealed sender (default on): route through the unauthenticated delivery
        // path so the relay never learns the sender — but ONLY for recipients that
        // support it (i.e. have published a sealed-sender access key). Recipients
        // on older builds, or when the sealed endpoint isn't deployed, won't have
        // one, so we fall back to the authenticated WebSocket path and can still
        // message them. Deciding per-recipient up front avoids double-sends.
        if sealedSenderEnabled, await recipientSupportsSealed(account) {
            try await sendContentSealed(
                payloadPlaintext, toPeer: account,
                clientTimestamp: clientTimestamp, ephemeral: ephemeral
            )
            return
        }
        // Sealed sends above go over REST; only the authenticated path needs
        // the live socket.
        guard socket != nil else { throw RelayWebSocketError.notConnected }
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

    /// Whether we can reach `account` via sealed sender — true once we know their
    /// sealed-sender access key (published by new builds; returned in the prekey
    /// bundle when the relay supports it). Fetches the bundle once if needed.
    private func recipientSupportsSealed(_ account: String) async -> Bool {
        if peerAccessKeys[account] != nil { return true }
        try? await refreshSessions(withPeer: account)
        return peerAccessKeys[account] != nil
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
            // Never build a Signal session with our own device: when refreshing our
            // OWN account (for linked-device sync), the server returns this device's
            // bundle too, and processPreKeyBundle rejects a session to self — which
            // would abort the whole refresh and silently break sync to other devices.
            if account == credentials.accountId && bundle.deviceId == credentials.deviceId {
                continue
            }
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
        // The official Relay chat and Note to Self have no real peer to poll,
        // pre-warm a session with, or send a profile to.
        let localOnlyPeers: Set<String> = [relayOfficialAccount, noteToSelfAccount]
        if let peer = resolvedPeerAccount(for: conversationId), localOnlyPeers.contains(peer) {
            stopPresencePolling()
            return
        }
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
                // Pre-warm the sealed-send path while the user reads/types, so the
                // first message is a single round-trip instead of chaining a cert
                // fetch + bundle fetch + send (which is what makes the first send
                // slow on bad networks).
                if peerAccessKeys[peer] == nil { try? await refreshSessions(withPeer: peer) }
                _ = try? await senderCertificate()
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
        // Local system lines and the official Relay chat have nobody to
        // receipt; they're only marked read locally.
        let receiptable = unread.filter { $0.senderAccount != Self.systemSender }
        let peer = try? peerAccount(for: conversationId)
        let hasRealPeer = peer != relayOfficialAccount && peer != noteToSelfAccount

        if sendReadReceipts, hasRealPeer, !receiptable.isEmpty {
            let unread = receiptable
            if let group = group(for: conversationId) {
                let byAuthor = Dictionary(grouping: unread) { $0.senderAccount ?? "" }
                for (author, msgs) in byAuthor where !author.isEmpty && author != credentials.accountId {
                    await sendReceipt(.read, timestamps: msgs.map(\.timestamp), toPeer: author, groupId: group.id)
                }
            } else if let peer {
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
        // Always ON: sealed sender is mandatory — the relay never learns who a
        // message is from. Not user-configurable (no UI toggle).
        get { true }
        set { }
    }

    /// Opt-in ciphertext-in-push. Off by default: pushes are a content-free wake
    /// and the device fetches + decrypts the envelope from the relay, so Apple's
    /// push servers carry no message data at all. When enabled, the relay embeds
    /// the (still end-to-end-encrypted) envelope in the APNs payload so alerts
    /// arrive faster without a fetch round-trip. Persisted locally and mirrored to
    /// the server, which decides per-device what to put in the push.
    var pushIncludeContent: Bool {
        get { UserDefaults.standard.bool(forKey: "relay.pushIncludeContent") }
        set {
            UserDefaults.standard.set(newValue, forKey: "relay.pushIncludeContent")
            Task { try? await self.api.setPushIncludeContent(newValue) }
        }
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
        hidePreviews: Bool
    ) {
        do {
            try storage.messages.setConversationPrivacy(
                conversationId,
                mediaRequiresBiometric: mediaRequiresBiometric,
                requireBiometricChat: requireBiometricChat,
                hidePreviews: hidePreviews
            )
            refreshConversations()
        } catch {
            log.error("set conversation privacy failed: \(PrivacyRedactor.error(error))")
        }
    }

    // MARK: - Screenshot protection

    /// Whether chat content should be hidden from screenshots/recordings for a
    /// conversation. Groups use the admin-set flag; DMs use the OR of both
    /// sides' preferences (both must disable it to turn it off).
    func effectiveScreenHidden(_ conversationId: String) -> Bool {
        if let group = group(for: conversationId) { return group.screenSecurity }
        guard let conv = conversations.first(where: { $0.id == conversationId }) else { return true }
        // Nothing to protect in your own notes or the official Relay chat.
        if conv.peerAccount == noteToSelfAccount || conv.peerAccount == relayOfficialAccount { return false }
        return conv.screenSecurity || conv.peerScreenSecurity
    }

    /// The local user's own screenshot-hide preference for a DM.
    func myScreenSecurityPref(_ conversationId: String) -> Bool {
        conversations.first { $0.id == conversationId }?.screenSecurity ?? true
    }

    /// Sets the local user's DM screenshot-hide preference and syncs it to the
    /// peer so the effective (OR) state stays consistent on both sides.
    func setScreenSecurity(_ enabled: Bool, conversationId: String) {
        guard let conv = conversations.first(where: { $0.id == conversationId }), !conv.isGroup else { return }
        try? storage.messages.setConversationScreenSecurity(conversationId, enabled: enabled)
        refreshConversations()
        let peer = conv.peerAccount
        guard !peer.isEmpty else { return }
        Task {
            var content = Relay_Content_Content()
            content.screenSecurityUpdate.enabled = enabled
            content.screenSecurityUpdate.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
            content.senderAccountID = credentials.accountId
            content.senderDeviceID = credentials.deviceId
            if let data = try? content.serializedData() {
                try? await sendContent(data, toPeer: peer, clientTimestamp: Int64(Date().timeIntervalSince1970 * 1000))
            }
        }
    }

    /// Admin-only: sets the group-wide screenshot-hide flag and distributes it.
    func setGroupScreenSecurity(_ enabled: Bool, conversationId: String) async throws {
        guard let group = group(for: conversationId) else { throw GroupError.notFound }
        try requireGroupAdmin(group)
        try storage.messages.setGroupScreenSecurity(id: group.id, enabled: enabled)
        guard let grp = try? storage.messages.group(id: group.id) else { return }
        var update = Relay_Content_GroupUpdate()
        update.action = .setScreenSecurity
        update.screenSecurity = enabled
        await sendGroupUpdateCustom(update, group: grp)
        let line = enabled ? "You turned on screenshot protection" : "You turned off screenshot protection"
        insertSystemLine(line, inGroup: group.id)
        refreshConversations()
    }

    /// Sends a screenshot alert to the other party (DM) or all members (group),
    /// regardless of the hide setting, and drops a local confirmation line.
    func sendScreenshotAlert(conversationId: String) {
        guard let conv = conversations.first(where: { $0.id == conversationId }) else { return }
        if conv.peerAccount == noteToSelfAccount || conv.peerAccount == relayOfficialAccount { return } // no one to notify
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        var content = Relay_Content_Content()
        content.screenshot.timestamp = ts
        content.senderAccountID = credentials.accountId
        content.senderDeviceID = credentials.deviceId

        let recipients: [String]
        if let group = group(for: conversationId) {
            content.groupID = group.id
            recipients = group.members.filter { $0 != credentials.accountId && !isBlocked($0) }
        } else {
            recipients = conv.peerAccount.isEmpty || isBlocked(conv.peerAccount) ? [] : [conv.peerAccount]
        }
        guard let data = try? content.serializedData() else { return }
        Task {
            for peer in recipients {
                try? await sendContent(data, toPeer: peer, clientTimestamp: ts)
            }
        }
        // Local confirmation shown to the screenshotter too.
        insertSystemLine("You took a screenshot", conversationId: conversationId)
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

    // MARK: - Official Relay account

    /// Ensures the official Relay system conversation exists (local, pinned,
    /// read-only) and returns its id. Posts a one-time welcome on first creation.
    @discardableResult
    func ensureRelayAccount() -> String {
        guard let id = try? storage.messages.conversation(
            withPeer: relayOfficialAccount, username: Self.relayOfficialUsername
        ) else { return "" }
        // The Relay chat should only ever contain Relay notices — strip any
        // stray system lines (e.g. "You took a screenshot" alerts inserted
        // before this chat was exempted from screenshot protection).
        if let existing = try? allMessages(in: id) {
            for m in existing where m.senderAccount == Self.systemSender {
                try? storage.messages.deleteMessage(id: m.id)
            }
        }
        if !UserDefaults.standard.bool(forKey: "relay.official.welcomed") {
            UserDefaults.standard.set(true, forKey: "relay.official.welcomed")
            insertRelayMessage(
                "Welcome to Relay 👋\n\nI'll let you know about important account activity here — like when a new device is linked to your account. You can't reply to this chat.",
                conversationId: id)
        }
        // Pin it once, when first created — after that it's the user's choice.
        if !UserDefaults.standard.bool(forKey: "relay.official.pinned") {
            UserDefaults.standard.set(true, forKey: "relay.official.pinned")
            setConversationPinned(id, pinned: true)
        }
        refreshConversations()
        refreshActiveMessages(ifShowing: id)
        return id
    }

    /// Posts a notice from Relay into the official system chat (creating it if
    /// needed). Renders as a normal incoming bubble; the chat stays read-only.
    func postRelayNotice(_ text: String) {
        let id = ensureRelayAccount()
        guard !id.isEmpty else { return }
        insertRelayMessage(text, conversationId: id)
    }

    private func insertRelayMessage(_ text: String, conversationId: String) {
        _ = try? storage.messages.insertMessage(
            id: UUID().uuidString, conversationId: conversationId, isOutgoing: false,
            body: text, timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            status: .received, senderAccount: relayOfficialAccount
        )
        refreshConversations()
        refreshActiveMessages(ifShowing: conversationId)
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
    func backfillUsernameIfNeeded(conversationId: String, account: String) {
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
        // The store decides: same key for a known device, or — for a device we
        // haven't seen — one of the keys this account already uses. Anything
        // else (including a brand-new device with a new key, which is what a
        // compromised relay would inject) is a safety-number change.
        guard try !storage.signalStore.isTrustedIdentity(
            incomingIdentity, for: address, direction: .sending, context: NullContext()
        ) else { return }

        _ = try storage.signalStore.saveIdentity(incomingIdentity, for: address, context: NullContext())
        refreshConversations()
        throw SafetyNumberChangedError(peer: peer)
    }

    private func requireAcknowledgedIdentity(forPeer peer: String) throws {
        if try isIdentityChangeAwaitingAcknowledgement(forPeer: peer) {
            throw SafetyNumberChangedError(peer: peer)
        }
    }

    /// True when the peer has any identity key (across all their devices) that
    /// the user hasn't acknowledged — a changed key or an unexpected device.
    private func isIdentityChangeAwaitingAcknowledgement(forPeer peer: String) throws -> Bool {
        let current = Set(try storage.signalStore.identityKeys(address: peer))
        guard !current.isEmpty else { return false }
        guard let acknowledged = try acknowledgedIdentities(forPeer: peer) else {
            // First contact (TOFU): acknowledge what we see.
            try acknowledgeIdentities(current, forPeer: peer)
            return false
        }
        return !current.isSubset(of: acknowledged)
    }

    private func acknowledgeCurrentIdentity(forPeer peer: String) throws {
        let current = Set(try storage.signalStore.identityKeys(address: peer))
        guard !current.isEmpty else { return }
        try acknowledgeIdentities(current, forPeer: peer)
    }

    private func acknowledgeIdentities(_ identities: Set<Data>, forPeer peer: String) throws {
        let value = try JSONEncoder().encode(identities.sorted { $0.lexicographicallyPrecedes($1) })
        try storage.database.run(
            "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
            [.text(Self.identityAcknowledgementKey(forPeer: peer)), .blob(value)]
        )
    }

    /// The acknowledged key set. Older builds stored a single raw key blob.
    private func acknowledgedIdentities(forPeer peer: String) throws -> Set<Data>? {
        guard let stored = try storage.database.query(
            "SELECT value FROM kv WHERE key = ?",
            [.text(Self.identityAcknowledgementKey(forPeer: peer))]
        ).first?.first?.data else { return nil }
        if let keys = try? JSONDecoder().decode([Data].self, from: stored) {
            return Set(keys)
        }
        return [stored]
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
    /// Delivers a control message (reaction, edit, unsend, typing) to whoever
    /// is on the other side of a conversation: the peer of a 1:1 chat, or every
    /// other member of a group (with the group id set so it lands in the group
    /// thread). Non-ephemeral content is mirrored to our own other devices.
    private func sendToConversation(
        _ content: Relay_Content_Content, conversationId: String,
        timestamp: Int64, ephemeral: Bool = false
    ) async {
        var content = content
        let recipients: [String]
        let syncPeer: String
        if let group = group(for: conversationId) {
            content.groupID = group.id
            recipients = group.members.filter { $0 != credentials.accountId && !isBlocked($0) }
            syncPeer = group.id
        } else if let peer = resolvedPeerAccount(for: conversationId),
                  peer != noteToSelfAccount, peer != relayOfficialAccount {
            recipients = [peer]
            syncPeer = peer
        } else {
            return
        }
        guard let data = try? content.serializedData() else { return }
        for recipient in recipients {
            do {
                try await sendContent(data, toPeer: recipient, clientTimestamp: timestamp, ephemeral: ephemeral)
            } catch {
                log.debug("control send skipped: \(PrivacyRedactor.error(error))")
            }
        }
        if !ephemeral {
            await sendSyncToOwnDevices(content: content, peer: syncPeer, timestamp: timestamp)
        }
    }

    func toggleReaction(_ emoji: String, on message: StoredMessage) {
        let conversationId = message.conversationId
        guard let peer = resolvedPeerAccount(for: conversationId) else { return }
        // In a group the target's author is the member who sent it, not the
        // conversation's "peer" (which is the group id).
        let targetAuthor = message.isOutgoing ? credentials.accountId : (message.senderAccount ?? peer)
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
            await sendToConversation(content, conversationId: conversationId, timestamp: content.reaction.timestamp)
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
        guard canUnsend(message) else { return }
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
            let ts = Int64(Date().timeIntervalSince1970 * 1000)
            await sendToConversation(content, conversationId: conversationId, timestamp: ts)
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
        Task {
            var content = Relay_Content_Content()
            content.edit.targetTimestamp = message.timestamp
            content.edit.newBody = newBody
            await sendToConversation(content, conversationId: conversationId, timestamp: now)
        }
    }

    // MARK: - Typing indicators (ephemeral)

    func sendTyping(_ action: Relay_Content_TypingMessage.Action, in conversationId: String) {
        Task {
            var content = Relay_Content_Content()
            content.typing.action = action
            content.typing.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
            await sendToConversation(
                content, conversationId: conversationId,
                timestamp: content.typing.timestamp, ephemeral: true
            )
        }
    }

    /// Who is typing in each conversation currently showing an indicator —
    /// lets a group chat name the member.
    private(set) var typingSenders: [String: String] = [:]

    private func applyPeerTyping(started: Bool, peerAccount: String?, groupConversationId: String? = nil) {
        guard let peerAccount,
              let conversationId = groupConversationId ?? existingConversation(withPeer: peerAccount) else { return }
        typingResetTasks[conversationId]?.cancel()
        typingResetTasks.removeValue(forKey: conversationId)
        if !started {
            typingConversations.remove(conversationId)
            typingSenders.removeValue(forKey: conversationId)
            return
        }
        typingConversations.insert(conversationId)
        typingSenders[conversationId] = peerAccount
        // Self-heal if the "stopped" frame is lost (ephemeral, never queued).
        typingResetTasks[conversationId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.typingConversations.remove(conversationId)
            self?.typingSenders.removeValue(forKey: conversationId)
            self?.typingResetTasks.removeValue(forKey: conversationId)
        }
    }

    private func clearPeerTyping(for conversationId: String) {
        typingResetTasks[conversationId]?.cancel()
        typingResetTasks.removeValue(forKey: conversationId)
        typingConversations.remove(conversationId)
        typingSenders.removeValue(forKey: conversationId)
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

    private var conversationsRefreshDirty = false

    func refreshConversations() {
        // Suppress per-envelope refreshes during the initial queue drain; the
        // connection loop fires one batch refresh at queueDrained instead.
        guard !isDrainingQueue else { return }
        // Coalesce rapid-fire calls into one deferred update so a burst of
        // envelopes doesn't trigger a re-render storm. The DB query runs on a
        // background thread to keep the main thread free.
        guard !conversationsRefreshScheduled else {
            // The in-flight query may already have read the DB before this
            // change landed — remember to run once more when it finishes.
            conversationsRefreshDirty = true
            return
        }
        conversationsRefreshScheduled = true
        conversationsRefreshDirty = false
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
                if self.conversationsRefreshDirty {
                    self.conversationsRefreshDirty = false
                    self.refreshConversations()
                }
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
