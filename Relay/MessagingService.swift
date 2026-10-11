//
//  MessagingService.swift
//  Relay
//
//  Ties CryptoCore, SecureStorage and RelayKit together: the connection loop,
//  the incoming-envelope pipeline, receipts, and per-device fan-out.
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

/// A labelled profile link, sent end-to-end encrypted in ProfileUpdate. `id`
/// is not encoded. `nonisolated` keeps Codable synthesis off the MainActor.
nonisolated struct ProfileLink: Codable, Hashable, Identifiable {
    var id = UUID()
    var label: String = ""
    var url: String = ""
    enum CodingKeys: String, CodingKey { case label, url }
}

enum MessagingError: LocalizedError {
    case attachmentTooLarge
    case recipientCannotReceivePrivately

    var errorDescription: String? {
        switch self {
        case .attachmentTooLarge: return "Attachment exceeds the 25 MB size limit."
        case .recipientCannotReceivePrivately:
            return "This contact's app can't receive sealed messages, so it wasn't sent. Ask them to update Relay."
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

/// Decrypted group-invite blob: what a joiner needs to bootstrap the group and
/// prove they held the link.
private struct GroupInvitePayload: Codable {
    let groupId: String
    let name: String
    let members: [String]
    let distributionId: String
    let inviteKey: Data
    /// Optional for links made by older builds.
    let admins: [String]?
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
        case .answer, .ice, .busy, .ringing, .groupJoin, .groupLeave, .linkRoster:
            return true
        // A join request must wake the host; admit/deny must reach a joiner
        // whose app was briefly backgrounded.
        case .offer, .hangup, .groupRing, .linkJoinRequest, .linkAdmit, .linkDeny, .UNRECOGNIZED:
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
    /// Encrypted chat-list sync (AccountStorage.swift).
    @ObservationIgnored var accountStorageUploadTask: Task<Void, Never>?
    @ObservationIgnored var lastChatListFingerprint: String?
    @ObservationIgnored private var siriPreviewTask: Task<Void, Never>?

    /// Refreshes the Siri UI snapshot a moment after the chat list settles.
    func scheduleSiriPreviewWrite() {
        siriPreviewTask?.cancel()
        siriPreviewTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self, !self.isShutDown else { return }
            SiriPreviewCache.write(service: self)
            WatchBridge.shared.push(service: self)
        }
    }
    private(set) var callHistory: [StoredCall] = []
    private(set) var activeMessages: [StoredMessage] = []
    private(set) var activeConversationId: String?
    /// Set to the conversation ID whose messages have just finished loading.
    /// Lets ChatView distinguish "still loading" from "genuinely empty".
    private(set) var messagesLoadedConversationId: String? = nil
    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var authenticationExpired = false
    /// Per-conversation so the chat list can show typing for chats that aren't open.
    private(set) var typingConversations: Set<String> = []
    /// Mute expiry per conversation: Int64.max = forever, positive = Unix ms expiry.
    private var muteExpiries: [String: Int64] = [:]
    var onCallMessage: ((CallInfo) async -> Void)?
    /// Called for a verified nuke command; must wipe local storage.
    var onNukeReceived: (() async -> Void)?
    /// The relay removed this device (replaced by a new sign-in, or unlinked);
    /// its credentials are dead, so sign out locally.
    var onRemovedFromAccount: (() async -> Void)?
    /// Set while this device is removing itself, so the relay's echo isn't
    /// mistaken for an external removal.
    var isRemovingSelf = false

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
    /// HTTP/3 queue polling for when the WebSocket can't connect (congested
    /// networks). The WebSocket stays the primary path.
    private var pollTask: Task<Void, Never>?
    /// Whether the WebSocket is up and draining; gates the poll fallback. Not the
    /// same as `connectionState`, which goes `.connected` once the server is
    /// reachable over QUIC, even without the TCP socket.
    private var socketLive = false
    private var expireTask: Task<Void, Never>?
    private var typingResetTasks: [String: Task<Void, Never>] = [:]
    private let log = Logger(subsystem: "com.relaytextingapp.Relay", category: "messaging")

    // Caches to keep DB queries out of SwiftUI render passes.
    private var nameCache: [String: String] = [:]
    private var avatarCache: [String: Data?] = [:]
    private var cachedActiveGroup: StoredGroup?? = nil  // nil = uncached; .some(nil) = confirmed 1:1
    // Coalesces rapid refresh calls into one deferred update.
    private var conversationsRefreshScheduled = false
    private var conversationsRefreshVersion: Int = 0
    // Suppresses per-envelope refreshes while draining the queue on connect.
    // Starts false so the init-time refreshConversations() populates App Group storage.
    private var isDrainingQueue = false
    /// Persisted in the encrypted kv table.
    private(set) var blockedAccounts: Set<String> = []
    /// Conversation that tried to send to a replacement identity key before
    /// the user acknowledged the new safety number.
    private(set) var blockedSafetyWarningConversationId: String?
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
            sealedSenderTrustRoot: RelayConfig.sealedSenderTrustRoot,
            processLock: .envelopeProcessing(appGroupId: AppModel.appGroupId)
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

    /// A 1:1 OFFER or a GROUP_RING the NSE decrypted, kept for the app to
    /// replay after the VoIP push wakes it.
    private struct PendingCallOffer: Codable {
        let callId: String
        let callerAccount: String
        let sdp: String
        var isGroupRing: Bool? = nil
        var groupId: String? = nil
        var ice: String? = nil
        var participants: [String]? = nil
    }

    private static let pendingCallOfferPrefix = "pending-call-offer:"

    /// Every call signal the NSE decrypted (OFFER, ICE, GROUP_RING, mesh
    /// messages...), kept in arrival order for the app to replay. Without the
    /// ICE candidates a call answered from the lock screen can't connect.
    private struct PendingCallMessage: Codable {
        let callId: String
        let type: CallInfo.CallType
        let sdp: String
        let ice: String
        let callerAccount: String
        let groupId: String
        let targetAccount: String
        let participants: [String]
        let receivedAt: Int64
    }

    private static let pendingCallMessagePrefix = "pending-call-msg:"

    /// For PushKitDelegate's VoIP token registration.
    var apiClient: RelayAPIClient { api }

    /// Redeems a one-time contact invite and returns the inviter's username.
    /// Throws if the token is spent or expired.
    func claimContactInvite(token: String) async throws -> String {
        let (_, username) = try await api.claimContactInvite(token: token)
        return username
    }

    /// Mints a one-time contact invite link.
    func createContactInviteLink() async throws -> URL {
        let (token, _) = try await api.createContactInvite()
        guard let url = URL(string: "https://relaymsg.app/c/\(token)") else {
            throw RelayAPIError.malformedResponse
        }
        return url
    }

    /// Best-effort; messaging works without push.
    func uploadPushToken(_ token: String) async {
        do {
            try await api.setAPNSToken(token)
        } catch {
            log.warning("apns token upload failed: \(PrivacyRedactor.error(error))")
        }
    }

    func publishInitialKeys() async throws {
        try await maintainer.publishInitialKeys(api: api, engine: engine, allocator: allocator)
    }

    /// Once per launch we re-publish a fresh signed prekey so the relay's bundle
    /// matches the local key store (a reinstall can wipe local keys while the
    /// server keeps the old ones).
    private var didRepublishKeysThisLaunch = false

    /// OFFER and HANGUP must survive offline delivery; ANSWER/ICE/BUSY/RINGING
    /// are live control traffic and must not trigger normal APNs alerts.
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

    func sendGroupCallMessage(_ msg: Relay_Content_CallMessage, toAccounts accounts: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { _ = await self.sendCallMessage(msg, to: account) }
            }
        }
    }

    func triggerGroupCallPushes(accounts: [String], callId: String, callerName: String, kind: CallKind) async {
        for account in accounts {
            await triggerCallPush(account: account, callId: callId)
        }
    }

    /// The ring is anonymous: it goes to each device's mailbox with the callee's
    /// access key, like a sealed send, and carries only the call id. The caller's
    /// identity travels in the encrypted OFFER.
    func triggerCallPush(account: String, callId: String) async {
        do {
            if knownAccessKey(account) == nil { try await refreshSessions(withPeer: account) }
            guard let accessKey = knownAccessKey(account) else { return }
            for device in try await knownMailboxDevices(ofPeer: account) {
                guard let mailbox = device.mailboxId, !mailbox.isEmpty else { continue }
                do {
                    try await api.ringCall(destinationMailbox: mailbox, accessKey: accessKey, callId: callId)
                } catch {
                    log.warning("call ring failed: \(PrivacyRedactor.error(error))")
                }
            }
        } catch {
            log.warning("call ring setup failed: \(PrivacyRedactor.error(error))")
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

    /// Replays call offers the NSE decrypted while the app was locked (it has to
    /// decrypt them to suppress the generic banner), so answering from CallKit
    /// can still send an ANSWER.
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

            let isGroupRing = offer.isGroupRing == true
            await onCallMessage?(CallInfo(
                callId: offer.callId,
                type: isGroupRing ? .groupRing : .offer,
                sdp: offer.sdp,
                ice: offer.ice ?? "",
                callerAccount: offer.callerAccount,
                groupId: offer.groupId ?? "",
                participants: offer.participants ?? []
            ))
            try? storage.database.run("DELETE FROM kv WHERE key = ?", [.text(key)])
        }

        // Then every other signal, in the order the NSE received it.
        let messages = (try? storage.database.query(
            "SELECT key, value FROM kv WHERE key LIKE ? ORDER BY key",
            [.text(Self.pendingCallMessagePrefix + "%")]
        )) ?? []
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for row in messages {
            guard let key = row.first?.string else { continue }
            try? storage.database.run("DELETE FROM kv WHERE key = ?", [.text(key)])
            guard let data = row.dropFirst().first?.data,
                  let m = try? JSONDecoder().decode(PendingCallMessage.self, from: data),
                  now - m.receivedAt < 120_000   // a call signal older than this is moot
            else { continue }
            await onCallMessage?(CallInfo(
                callId: m.callId, type: m.type, sdp: m.sdp, ice: m.ice, callerAccount: m.callerAccount,
                groupId: m.groupId, targetAccount: m.targetAccount, participants: m.participants
            ))
        }
    }

    private var didSweepInterruptedSends = false

    // MARK: Demo accounts (App Review)

    static let demoAccountKey = "relay.isDemoAccount"

    /// Server-flagged demo account: it can only reach other demo accounts and
    /// its login can't change.
    var isDemoAccount: Bool = UserDefaults.standard.bool(forKey: MessagingService.demoAccountKey)

    /// For a demo account, also adds the other demo accounts to the chat list.
    func refreshDemoStatus() async {
        guard let status = try? await apiClient.demoStatus() else { return }
        isDemoAccount = status.demo
        UserDefaults.standard.set(status.demo, forKey: Self.demoAccountKey)
        guard status.demo else { return }
        for peer in status.peers where !conversations.contains(where: { !$0.isGroup && $0.peerUsername == peer }) {
            _ = try? await startConversation(username: peer)
        }
    }

    /// Set at sign-out. Callbacks that still hold this service (a VoIP wake,
    /// a debounced preview write) must not bring the old account back.
    private(set) var isShutDown = false

    /// Stops for good: the account is being signed out or wiped.
    func shutDown() {
        isShutDown = true
        siriPreviewTask?.cancel()
        siriPreviewTask = nil
        stop()
    }

    func start() {
        guard connectionTask == nil, !isShutDown else { return }
        Task { await refreshDemoStatus() }
        if !didSweepInterruptedSends {
            // Only on the first start of this process: nothing can be mid-send
            // yet, so anything still "sending" was interrupted by a kill.
            didSweepInterruptedSends = true
            failInterruptedSends()
        }
        connectionTask = Task { await runConnectionLoop() }
        pollTask = Task { [weak self] in await self?.runQueuePollLoop() }
        Task { [weak self] in await self?.publishDeviceLabel(force: false) }
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
        // Lets a background refresh know it must start() the service again.
        connectionState = .disconnected
        socketLive = false
        isDrainingQueue = false
        let socket = socket
        self.socket = nil
        guard let socket else { return }
        // Stay alive long enough to send the WebSocket close; otherwise the
        // relay may consider us online until its ~60s pong timeout and not push.
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
                // QUIC preflight. This races HTTP/3, so it can succeed on congested
                // networks where the TCP WebSocket can't; the app is then usable
                // (send over HTTP/3, receive via the poll loop), so mark connected.
                _ = try await api.listDevices()
                authenticationExpired = false
                connectionState = .connected
                isDrainingQueue = false
                // Warm the sealed-sender certificate (cached ~7 days).
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
            // Apply NSE-stored control messages before newer queued envelopes.
            await drainPendingControlMessages(sendReceipts: false)
            let socket = RelayWebSocket(baseURL: serverURL, credentials: credentials, session: session,
                                        signer: DeviceAuthSigner(keychain: keychain))
            self.socket = socket
            for await event in await socket.connect() {
                switch event {
                case .queueDrained:
                    socketLive = true
                    isDrainingQueue = false
                    connectionState = .connected
                    backoffSeconds = 1.0
                    refreshConversations()
                    // With the socket live, send the receipts the NSE deferred.
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
                    await ensureNoteToSelf()
                    ensureRelayAccount()
                case .envelope(let envelope):
                    await handleEnvelope(envelope)
                case .nukeCommand(let nuke):
                    await handleNukeEvent(nuke)
                case .deviceListChanged(let change):
                    if change.action == .removed, change.deviceId == credentials.deviceId {
                        guard !isRemovingSelf else { break }
                        await onRemovedFromAccount?()
                        return
                    }
                    Task { try? await self.refreshDeviceList() }
                    // A new device of ours needs our label to show us by name.
                    if change.action == .added {
                        Task { await self.publishDeviceLabel(force: true) }
                    }
                case .disconnected:
                    isDrainingQueue = false
                    break
                }
            }
            self.socket = nil
            socketLive = false
            isDrainingQueue = false
            // Don't force `.disconnected`: we may still be usable via QUIC and
            // the poll loop, and the next preflight re-checks reachability.
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(backoffSeconds))
            backoffSeconds = min(backoffSeconds * 2, 30)
        }
    }

    // MARK: - Incoming pipeline

    /// Pulls queued envelopes over HTTP/3 while the WebSocket is down. Dedup by
    /// envelope id makes overlap with the socket harmless.
    private func runQueuePollLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            // Keyed on the socket, not connectionState (which may be "connected" via QUIC).
            guard !socketLive else { continue }
            guard let envelopes = try? await api.fetchQueue() else { continue }
            for envelope in envelopes {
                await handleEnvelope(envelope)
            }
        }
    }

    /// Acks over the WebSocket when live, else over REST.
    private func ackEnvelope(_ id: String) async {
        if socketLive, let socket {
            try? await socket.ack(envelopeId: id)
        } else {
            try? await api.ackMessage(envelopeId: id)
        }
    }

    /// Tail of the envelope-processing chain. The WebSocket and poll loops can
    /// overlap; chaining keeps decrypts (and ratchet advances) strictly serial.
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
        // Always ack, or an undecryptable envelope would redeliver forever.
        defer {
            Task { await self.ackEnvelope(envelope.id) }
        }
        // Blocked senders are still decrypted to keep the ratchet in step, then
        // dropped by `process(_:blockedAccounts:)`.
        do {
            // Off the main thread; `handleEnvelope`'s chain keeps it serial.
            let proc = processor
            let blocked = blockedAccounts
            let result = try await Task.detached(priority: .userInitiated) {
                try proc.process(envelope, blockedAccounts: blocked)
            }.value
            await applyProcessed(result, outerSender: envelope.senderAccount)
        } catch {
            log.error("failed to process encrypted envelope: \(PrivacyRedactor.error(error))")
            handlePossiblePreKeyDesync(error)
        }
    }

    /// Group messages that arrived before their group (see
    /// `EnvelopeProcessor.replayDeferredGroupContent`), now that group updates
    /// have been applied.
    func replayDeferredGroupContent() async {
        let proc = processor
        let blocked = blockedAccounts
        let results = await Task.detached(priority: .userInitiated) {
            proc.replayDeferredGroupContent(blockedAccounts: blocked)
        }.value
        for result in results {
            await applyProcessed(result, outerSender: "")
        }
    }

    private func applyProcessed(_ result: ProcessedEnvelope, outerSender: String) async {
        do {
            if let timestamp = result.sideEffects.deliveryReceiptTimestamp {
                let groupId = result.conversationId.flatMap { group(for: $0)?.id }
                // Sealed envelopes have no outer sender; receipt the identity
                // authenticated by decryption.
                await sendReceipt(.delivery, timestamps: [timestamp], toPeer: result.peerAccount ?? outerSender, groupId: groupId)
            }
            // The processor may have just recorded the sender's certificate-
            // attested username; drop any memoized fallback name.
            if let peer = result.peerAccount { nameCache[peer] = nil }
            if let typingStarted = result.typingStarted {
                applyPeerTyping(started: typingStarted, peerAccount: result.peerAccount,
                                groupConversationId: result.conversationId)
            }
            if result.outcome == .stored, let conversationId = result.conversationId {
                clearPeerTyping(for: conversationId) // a real message ends typing
                // @mentions still notify in muted conversations.
                if let body = result.notification?.body,
                   let me = username,
                   Mentions.contains(body, username: me),
                   isConversationMuted(conversationId),
                   activeConversationId != conversationId
                {
                    postMentionNotification(body: body, senderAccount: result.peerAccount ?? "")
                }
            }
            if let conversationId = result.conversationId {
                refreshConversations()
                refreshActiveMessages(ifShowing: conversationId)
                // Open conversation: mark read right away.
                if activeConversationId == conversationId {
                    Task { await markVisibleMessagesRead(in: conversationId) }
                }
                // Special-prefix messages (notepad, location). Use this envelope's
                // body; `activeMessages` refreshes asynchronously and is stale here.
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
                await replayDeferredGroupContent()
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

    /// A `PreKeySignalMessage` referencing a prekey we no longer hold means the
    /// relay's published pool is out of sync with ours (usually after a
    /// reinstall). That envelope is lost, but we re-publish so future sessions
    /// work.
    private var didHealPreKeyPoolThisLaunch = false
    private static let preKeyDesyncCountKey = "prekey-desync-drop-count"

    private func handlePossiblePreKeyDesync(_ error: Error) {
        guard case StorageError.recordNotFound(let what) = error,
              what.contains("prekey") else { return }
        // Counted for diagnostics even if we've already healed this launch.
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

    /// Envelopes dropped due to prekey-pool desync; shown in diagnostics when non-zero.
    var preKeyDesyncDropCount: Int {
        guard let data = try? storage.database.query(
            "SELECT value FROM kv WHERE key = ?", [.text(Self.preKeyDesyncCountKey)]
        ).first?.first?.data, let s = String(data: data, encoding: .utf8), let n = Int(s) else {
            return 0
        }
        return n
    }

    // MARK: - Blinded discovery

    /// Blinded discovery is unavailable on the server (no OPRF key). There is
    /// deliberately no fallback to the plaintext `by-username` lookup, which
    /// would reveal the username to the relay.
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
        // The directory includes their access key, so even the first bundle
        // fetch is anonymous.
        if let accessKey = match.accessKey, match.accountId != credentials.accountId {
            rememberAccessKey(accessKey, for: match.accountId)
        }
        return match.accountId
    }

    /// Matches address-book emails against the directory. The relay learns
    /// which registered users matched but never sees any email in plaintext.
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

    /// Starts or reopens a conversation, resolving the username via blinded discovery.
    func startConversation(username: String) async throws -> String {
        let account = try await resolveAccount(username: username)
        let id = try storage.messages.conversation(withPeer: account, username: username)
        // Starting a chat with someone whose request is waiting accepts it.
        if conversations.first(where: { $0.id == id })?.isRequest == true { acceptMessageRequest(id) }
        refreshConversations()
        return id
    }

    // MARK: - Message requests

    /// Unaccepted chats someone else started, newest first.
    var messageRequests: [Conversation] { conversations.filter { $0.isRequest && !$0.archived } }

    func isMessageRequest(_ conversationId: String) -> Bool {
        conversations.first { $0.id == conversationId }?.isRequest ?? false
    }

    /// Whether we've accepted (or started) a 1:1 chat with `account`.
    private func hasAcceptedChat(with account: String) -> Bool {
        conversations.contains { !$0.isGroup && $0.peerAccount == account && !$0.isRequest }
    }

    /// Who may ring us: someone we've accepted a chat with, or a member of a
    /// group we've accepted. Anyone else is a message request.
    func isCallAllowed(from account: String) -> Bool {
        if hasAcceptedChat(with: account) { return true }
        return conversations.contains { conv in
            conv.isGroup && !conv.isRequest && (group(for: conv.id)?.members.contains(account) ?? false)
        }
    }

    /// A call from a message request doesn't ring; it leaves a note in the
    /// request instead.
    func noteCallFromRequest(_ account: String) {
        guard !isBlocked(account),
              let conversationId = try? storage.messages.conversation(withPeer: account, accepted: false)
        else { return }
        insertSystemLine("Missed call. Accept the request to get calls from them.", conversationId: conversationId)
    }

    /// Accepts a request: from now on the sender sees read receipts and typing,
    /// gets our profile, and media and links show.
    func acceptMessageRequest(_ conversationId: String) {
        guard let conv = conversations.first(where: { $0.id == conversationId }), conv.isRequest else { return }
        try? storage.messages.setConversationAccepted(conversationId, accepted: true)
        refreshConversations()
        refreshActiveMessages(ifShowing: conversationId)
        Task {
            if let groupId = conv.groupId, let group = try? storage.messages.group(id: groupId) {
                await distributeProfileToGroupMembersIfNeeded(group: group)
            } else {
                await sendMyProfileIfNeeded(toPeer: conv.peerAccount)
            }
            if activeConversationId == conversationId { markConversationRead(conversationId) }
        }
    }

    /// Unlike `sendMessage`, updates collapse into one bubble per sharer per
    /// conversation, locally and on the recipient (see EnvelopeProcessor).
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
                for member in group.members where member != credentials.accountId && !isBlocked(member) {
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
        if isMessageRequest(conversationId) { acceptMessageRequest(conversationId) }
        let group = try? groupForConversation(conversationId)
        if let group {
            // Announce-only: only admins may send.
            if group.isAnnounceOnly && !group.admins.contains(credentials.accountId) { return }
        } else {
            guard let peer = try? peerAccount(for: conversationId) else { return }
            // The chat UI hides the composer for blocked peers; this is a backstop.
            if isBlocked(peer) { return }

            // Note to Self: libsignal can't hold a session with its own address,
            // so store locally. Attachments stay sealed on-device.
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

        // Store before any network work so a failed upload or send leaves a
        // retryable bubble instead of losing the message.
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

        // Opt-in random send delay (cover traffic).
        await applySendJitter()
        await transmit(
            messageId: localId, conversationId: conversationId, body: text,
            timestamp: timestamp, replyTo: replyTo, attachments: stored
        )
    }

    /// Keeps the original timestamp (receipts and quotes reference it) and skips
    /// group members an earlier attempt already reached.
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

    private func sealLocally(_ pending: [PendingAttachment]) throws -> [StoredAttachment] {
        // The server caps ciphertext at 26 MB.
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

    /// Uploads local-only attachments, renaming the row and cache entry to the
    /// relay's blob id. Already-uploaded ones are reused on retry.
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

    /// Marks the message sent, or failed for `retrySend`.
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
                // The group fan-out excludes our own account.
                await sendSyncToOwnDevices(content: content, peer: group.id, timestamp: timestamp)
            } else {
                guard let peer = try peerAccount(for: conversationId) else {
                    throw GroupError.notFound
                }
                Task { await sendMyProfileIfNeeded(toPeer: peer) }
                try await sendContent(try content.serializedData(), toPeer: peer, clientTimestamp: timestamp)
                try storage.messages.updateStatus(messageId: messageId, status: .sent)
                donateInteraction(peerAccount: peer, conversationId: conversationId)
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

    /// Fails sends interrupted by the app being killed, so they offer Retry.
    private func failInterruptedSends() {
        try? storage.database.run(
            "UPDATE messages SET status = ? WHERE is_outgoing = 1 AND status = ?",
            [.text(MessageStatus.failed.rawValue), .text(MessageStatus.sending.rawValue)]
        )
    }

    /// Best-effort. Bypasses sendContent to exclude this device and skip the
    /// identity acknowledgement check (own devices are trusted).
    private func sendSyncToOwnDevices(
        content: Relay_Content_Content,
        peer: String,
        timestamp: Int64
    ) async {
        var sync = content
        sync.syncRecipient = peer
        guard let data = try? sync.serializedData(),
              let padded = try? ContentPadding.pad(data) else { return }

        // Always fetch fresh to catch newly linked devices.
        var devices: [PeerDevice]
        do {
            try await refreshSessions(withPeer: credentials.accountId)
            // Not knownMailboxDevices: an empty list (no other devices) isn't an error.
            devices = knownDevices(ofPeer: credentials.accountId)
                .filter { $0.id != credentials.deviceId && !($0.mailboxId ?? "").isEmpty }
        } catch {
            log.warning("self-sync: resolve own devices failed: \(PrivacyRedactor.error(error))")
            return
        }
        guard !devices.isEmpty else {
            log.debug("self-sync: no other own devices to sync to")
            return
        }
        do {
            // Sealed too: an authenticated self-send alongside a sealed send
            // would reveal the sender.
            if sealedSenderEnabled, await recipientSupportsSealed(credentials.accountId) {
                try await sendContentSealed(
                    padded, toPeer: credentials.accountId,
                    clientTimestamp: timestamp, ephemeral: false
                )
                log.debug("self-sync: sealed to \(devices.count) own device(s)")
                return
            }
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
    /// Note to Self uses the user's own account id.
    var noteToSelfAccount: String { credentials.accountId }

    /// Peer id of the read-only "Relay" system chat for account notices. The
    /// `relay` username is reserved server-side so it can't be impersonated.
    static let relayOfficialAccount = "relay.official"
    static let relayOfficialUsername = "relay"
    var relayOfficialAccount: String { Self.relayOfficialAccount }

    func group(for conversationId: String) -> StoredGroup? {
        try? groupForConversation(conversationId)
    }

    /// Groups shared with a peer, computed from local rosters.
    func mutualGroups(with account: String) -> [(id: String, name: String)] {
        conversations.compactMap { conv in
            guard conv.isGroup,
                  let g = group(for: conv.id),
                  g.members.contains(account) else { return nil }
            return (conv.id, g.name)
        }
    }

    /// "You", then nickname, then username, then a short account prefix.
    /// Cached to keep DB reads out of render.
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

    /// The username only, without nickname or prefix fallback.
    func username(forAccount account: String) -> String? {
        if let cached = cachedUsername(account) { return cached }
        return (try? storage.database.query(
            "SELECT peer_username FROM conversations WHERE peer_account = ?", [.text(account)]
        ).first?.first?.string) ?? nil
    }

    /// User-set display-name override, stored in kv by account id.
    func nickname(forAccount account: String) -> String? {
        (try? storage.database.query(
            "SELECT value FROM kv WHERE key = ?", [.text("nick:\(account)")]
        ).first?.first?.data).flatMap { $0 }.flatMap { String(bytes: $0, encoding: .utf8) }
    }

    /// An empty name clears the override.
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
        nameCache[account] = nil
        refreshConversations()
        if let id = activeConversationId { refreshActiveMessages(ifShowing: id) }
    }

    // MARK: - Own profile

    /// Stored locally in kv.
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

    /// Already downscaled by the caller. Stored locally in kv.
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

    /// Status and bio are stored locally in UserDefaults.
    var myStatus: String { UserDefaults.standard.string(forKey: "my.profile.status") ?? "" }
    var myBio: String { UserDefaults.standard.string(forKey: "my.profile.bio") ?? "" }

    var myLinks: [ProfileLink] {
        Self.decodeLinks(UserDefaults.standard.string(forKey: "my.profile.links"))
    }

    /// Bumps the profile revision if anything changed, so peers get the update.
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

    /// Links persist as JSON, in UserDefaults for self and the profiles table for peers.
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

    // MARK: - Profile distribution

    /// Bumped on every profile change. Peers keep the newest revision, and a
    /// bump re-arms sending to every peer.
    private var myProfileRevision: Int64 {
        readKVInt("me:rev")
    }

    private func bumpMyProfileRevision() {
        writeKVInt("me:rev", Int64(Date().timeIntervalSince1970 * 1000))
        // The cached avatar upload belongs to the old revision.
        try? storage.database.run("DELETE FROM kv WHERE key IN ('me:aptr', 'me:aptrrev')")
        distributeProfileUpdate()
    }

    /// Sends the updated profile to every DM peer and group member.
    private func distributeProfileUpdate() {
        let accepted = conversations.filter { !$0.isRequest }
        let dmPeers = accepted
            .filter { !$0.isGroup }
            .compactMap { $0.peerAccount.isEmpty ? nil : $0.peerAccount }
        // group_state is keyed by group id, not conversation id.
        let groupMembers: [String] = accepted
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

    /// Sends our profile if the peer hasn't received this revision.
    private func sendMyProfileIfNeeded(toPeer account: String) async {
        // Someone we blocked gets no name, photo or bio, even through a group.
        if isBlocked(account) { return }
        // A requester gets our name and photo only once we accept, unless we
        // share an accepted group with them.
        if (try? storage.messages.isMessageRequest(peer: account)) == true {
            let inAcceptedGroup = conversations.contains { conv in
                guard !conv.isRequest, let gid = conv.groupId else { return false }
                return (try? storage.messages.group(id: gid))?.members.contains(account) == true
            }
            if !inAcceptedGroup { return }
        }
        // Sent at least once (revision 1) even with nothing set: this is how
        // peers learn our username without asking the relay who an account is.
        let rev = max(myProfileRevision, 1)
        guard readKVInt("pfsent:\(account)") < rev else { return }
        do {
            var content = Relay_Content_Content()
            content.profile.displayName = myDisplayName ?? ""
            content.profile.timestamp = rev
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

    /// Uploads the avatar once per revision and caches the pointer.
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

    /// Newest revision wins; a changed avatar is downloaded via the blob pipeline.
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
                    // Don't advance the revision, so the next delivery retries.
                    avatarReady = false
                }
            }
        } else {
            avatarData = nil // peer cleared their photo
            avatarId = nil
        }
        // Keep the old revision on avatar failure so the next delivery retries.
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
        nameCache[profile.account] = nil
        avatarCache[profile.account] = nil
        refreshConversations()
        if let id = activeConversationId { refreshActiveMessages(ifShowing: id) }
    }

    func peerStatus(forAccount account: String) -> String {
        if account == credentials.accountId { return "" }
        return ((try? storage.messages.peerProfile(account: account)) ?? nil)?.status ?? ""
    }

    func peerBio(forAccount account: String) -> String {
        if account == credentials.accountId { return myBio }
        return ((try? storage.messages.peerProfile(account: account)) ?? nil)?.bio ?? ""
    }

    func peerLinks(forAccount account: String) -> [ProfileLink] {
        if account == credentials.accountId { return myLinks }
        let json = ((try? storage.messages.peerProfile(account: account)) ?? nil)?.linksJSON
        return Self.decodeLinks(json)
    }

    func peerAvatarData(forAccount account: String) -> Data? {
        // Our own avatar is in kv, not the profiles table.
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
        // ChatView renders the "call:" prefix with a phone icon.
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
        // displayName may have cached the account-id fallback.
        nameCache[account] = nil
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

    func flushDueScheduledMessages() async {
        let now = Date().timeIntervalSince1970
        let due = scheduledMessages().filter { $0.scheduledAt <= now }
        for msg in due {
            cancelScheduled(id: msg.id)
            await sendMessage(msg.body, in: msg.conversationId)
        }
    }

    private func insertSystemLine(_ text: String, inGroup groupId: String) {
        guard let conversationId = (try? storage.messages.groupConversationId(groupId: groupId)) ?? nil else { return }
        insertSystemLine(text, conversationId: conversationId)
    }

    func insertSystemLine(_ text: String, conversationId: String) {
        _ = try? storage.messages.insertMessage(
            id: UUID().uuidString, conversationId: conversationId, isOutgoing: false,
            body: text, timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            status: .received, senderAccount: Self.systemSender
        )
        refreshConversations()
        refreshActiveMessages(ifShowing: conversationId)
    }

    private func groupForConversation(_ conversationId: String) throws -> StoredGroup? {
        guard let groupId = try storage.database.query(
            "SELECT group_id FROM conversations WHERE id = ?", [.text(conversationId)]
        ).first?.first?.string else { return nil }
        return try storage.messages.group(id: groupId)
    }

    /// Legacy groups with no recorded admins are open to every member.
    private func requireGroupAdmin(_ group: StoredGroup) throws {
        guard Self.isGroupAdmin(credentials.accountId, in: group) else {
            throw GroupError.notAdmin
        }
    }

    /// An admin must be a current member. Legacy groups with no admin list
    /// treat every member, and only members, as admins.
    static func isGroupAdmin(_ account: String, in group: StoredGroup) -> Bool {
        guard group.members.contains(account) else { return false }
        return group.admins.isEmpty || group.admins.contains(account)
    }

    /// Groups are entirely client-side; the relay never learns a group exists,
    /// its name or its members. Returns the conversation id.
    func createGroup(name: String, memberUsernames: [String]) async throws -> String {
        var members: [String] = [credentials.accountId]
        for username in memberUsernames {
            let account = try await resolveAccount(username: username)
            if !members.contains(account) { members.append(account) }
            try? await refreshSessions(withPeer: account) // pairwise sessions for SKDM/control
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
        if let stored = try storage.messages.group(id: groupId) {
            await distributeProfileToGroupMembersIfNeeded(group: stored)
        }
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
            try? await distributeSenderKeyIfNeeded(group: stored)
            await sendGroupUpdate(.add, group: stored, target: account)
        }
        insertSystemLine("You added \(username)", inGroup: groupId)
    }

    func removeGroupMember(_ account: String, fromGroup groupId: String) async throws {
        guard let existing = try storage.messages.group(id: groupId) else { throw GroupError.notFound }
        try requireGroupAdmin(existing)
        let members = existing.members.filter { $0 != account }
        // Rotate the sender-key epoch so the removed member can't read future
        // messages: a new distribution id makes every member mint a new key.
        let newDistributionId = UUID().uuidString
        try storage.messages.upsertGroup(
            id: groupId, name: existing.name, distributionId: newDistributionId,
            revision: existing.revision + 1, members: members,
            admins: existing.admins.filter { $0 != account }, isAnnounceOnly: existing.isAnnounceOnly
        )
        // The removed member knows the invite capability; replace it so they
        // can't rejoin.
        if groupInviteKey(groupId) != nil {
            setGroupInviteKey(groupId, Self.randomInviteKey())
        }
        refreshConversations()
        if let stored = try storage.messages.group(id: groupId) {
            try? await distributeSenderKeyIfNeeded(group: stored)
            await sendGroupUpdate(.remove, group: stored, target: account)
            // Tell the removed member too, without the new invite key.
            var notice = Relay_Content_GroupUpdate()
            notice.action = .remove
            notice.target = account
            await sendGroupUpdateCustom(notice, group: stored, to: [account], includeInviteKey: false)
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
        // Same encrypted-attachment path as media.
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

    /// The relay stores only ciphertext; the key is in the URL fragment. The
    /// embedded invite capability lets members verify a joiner held the link.
    func createGroupInviteLink(groupId: String) async throws -> String {
        guard let group = try storage.messages.group(id: groupId) else { throw GroupError.notFound }
        try requireGroupAdmin(group)
        // First link: create the invite capability and silently share it with members.
        if groupInviteKey(groupId) == nil {
            setGroupInviteKey(groupId, Self.randomInviteKey())
            var announce = Relay_Content_GroupUpdate()
            announce.action = .unspecified // silent; carries only the invite key
            await sendGroupUpdateCustom(announce, group: group)
        }
        guard let inviteKey = groupInviteKey(groupId) else { throw GroupError.notFound }
        let payload = GroupInvitePayload(
            groupId: groupId, name: group.name, members: group.members,
            distributionId: group.distributionId, inviteKey: inviteKey, admins: group.admins
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

        // Record the link in the Relay chat so it can't happen silently.
        postRelayNotice("A new device (device \(deviceId)) was linked to your account. If this wasn't you, unlink it in Settings → Linked Devices and change your recovery details.")
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

    // MARK: - Backup snapshot

    /// Local chat state; CloudBackupManager encrypts it before it leaves the device.
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
            /// Nil in older backups (treated as accepted).
            var accepted: Bool?
            var disappearingSeconds: Int64?
            var mediaRequiresBiometric: Bool?
            var requireBiometricChat: Bool?
            var hidePreviews: Bool?
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

    /// Leaves out what the user expects not to outlive this device: chats
    /// hidden by Panic Mode, disappearing messages and view-once media.
    func exportBackupSnapshot() -> BackupSnapshot {
        var convs: [BackupSnapshot.Conversation] = []
        var groups: [BackupSnapshot.Group] = []
        let hidden = PanicModeManager.hiddenConversationIdsSnapshot()
        for conv in (try? storage.messages.conversations()) ?? [] where !hidden.contains(conv.id) {
            let expiring = Set(((try? storage.database.query(
                "SELECT id FROM messages WHERE conversation_id = ? AND expires_at IS NOT NULL", [.text(conv.id)]
            )) ?? []).compactMap { $0.first?.string })
            let kept = ((try? storage.messages.messages(in: conv.id, limit: 100_000)) ?? []).filter {
                !expiring.contains($0.id) && !$0.body.hasPrefix("~once~") && !$0.isDeleted
            }
            let msgs = kept.map { m in
                BackupSnapshot.Message(
                    id: m.id, body: m.body, timestamp: m.timestamp,
                    isOutgoing: m.isOutgoing, status: m.status.rawValue, senderAccount: m.senderAccount,
                    replyTimestamp: m.replyTo?.targetTimestamp,
                    replyAuthor: m.replyTo?.author, replyText: m.replyTo?.text
                )
            }
            convs.append(BackupSnapshot.Conversation(
                peerAccount: conv.peerAccount, username: conv.peerUsername,
                groupId: conv.groupId, messages: msgs,
                accepted: conv.accepted, disappearingSeconds: conv.disappearingSeconds,
                mediaRequiresBiometric: conv.mediaRequiresBiometric,
                requireBiometricChat: conv.requireBiometricChat, hidePreviews: conv.hidePreviews
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

    /// Idempotent: existing message ids are skipped.
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
                // The group was upserted above; never create it via the
                // 1:1-only conversation(withPeer:).
                convId = ((try? storage.messages.groupConversationId(groupId: gid)) ?? nil) ?? ""
            } else {
                convId = (try? storage.messages.conversation(
                    withPeer: c.peerAccount, username: c.username, accepted: c.accepted ?? true)) ?? ""
            }
            guard !convId.isEmpty else { continue }
            // The restored chat keeps its request state and locks.
            if c.accepted == false { try? storage.messages.setConversationAccepted(convId, accepted: false) }
            if c.mediaRequiresBiometric != nil || c.requireBiometricChat != nil || c.hidePreviews != nil {
                try? storage.messages.setConversationPrivacy(
                    convId,
                    mediaRequiresBiometric: c.mediaRequiresBiometric ?? false,
                    requireBiometricChat: c.requireBiometricChat ?? false,
                    hidePreviews: c.hidePreviews ?? false
                )
            }
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
            // After the inserts: restored messages predate the timer and must
            // not start expiring now.
            if let secs = c.disappearingSeconds, secs > 0 {
                try? storage.messages.setDisappearingSeconds(convId, seconds: secs)
            }
            try? storage.messages.markConversationRead(convId)
        }
        refreshConversations()
    }

    /// Empty conversations for a newly linked device's synced chat list.
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

    private func handleNukeEvent(_ nuke: NukeEvent) async {
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

    private func refreshDeviceList() async throws {
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

    /// Decrypts an invite for preview; stores nothing and contacts no member.
    /// `fragment` is the base64url key||digest from the link's fragment.
    func previewGroupInvite(token: String, fragment: String) async throws -> GroupInvitePreview {
        guard let keyDigest = Data(base64URLEncoded: fragment), keyDigest.count == 64 else {
            throw RelayAPIError.malformedResponse
        }
        let blob = try await api.claimEncryptedGroupInvite(token: token)
        let json = try AttachmentCipher.open(
            blob, key: Data(keyDigest.prefix(32)), digest: Data(keyDigest.suffix(32))
        )
        let payload = try JSONDecoder().decode(GroupInvitePayload.self, from: json)
        guard Self.isValidGroupId(payload.groupId, ownAccount: credentials.accountId) else {
            throw GroupError.notFound
        }
        var preview = GroupInvitePreview(groupName: payload.name, memberCount: payload.members.count, payload: json)
        if let existing = try storage.messages.group(id: payload.groupId),
           existing.members.contains(credentials.accountId) {
            preview.existingConversationId = try storage.messages.groupConversationId(groupId: payload.groupId)
        }
        return preview
    }

    /// Announces the join with the invite capability echoed, so a non-admin
    /// self-add is accepted.
    func acceptGroupInvite(_ preview: GroupInvitePreview) async throws -> String {
        let payload = try JSONDecoder().decode(GroupInvitePayload.self, from: preview.payload)
        guard Self.isValidGroupId(payload.groupId, ownAccount: credentials.accountId) else {
            throw GroupError.notFound
        }
        // Already a member: the invite's snapshot is older than our state and
        // could restore members removed since the link was made.
        if let existing = try storage.messages.group(id: payload.groupId),
           existing.members.contains(credentials.accountId) {
            return try storage.messages.groupConversationId(groupId: payload.groupId) ?? ""
        }

        var members = payload.members
        if !members.contains(credentials.accountId) { members.append(credentials.accountId) }
        setGroupInviteKey(payload.groupId, payload.inviteKey)
        try storage.messages.upsertGroup(
            id: payload.groupId, name: payload.name, distributionId: payload.distributionId,
            revision: 1, members: members,
            // Keep the group's real admins; an empty list would make every
            // member an admin from this device's point of view.
            admins: (payload.admins ?? []).filter { payload.members.contains($0) }
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
            await sendGroupUpdateCustom(join, group: stored)
        }
        insertSystemLine("You joined via invite link", inGroup: payload.groupId)
        if let stored = try storage.messages.group(id: payload.groupId) {
            await distributeProfileToGroupMembersIfNeeded(group: stored)
        }
        return try storage.messages.groupConversationId(groupId: payload.groupId) ?? ""
    }

    func leaveGroup(_ groupId: String) async throws {
        guard let existing = try storage.messages.group(id: groupId) else { throw GroupError.notFound }
        let remaining = existing.members.filter { $0 != credentials.accountId }
        let announce = StoredGroup(
            id: existing.id, name: existing.name, distributionId: existing.distributionId,
            revision: existing.revision + 1, members: remaining,
            admins: existing.admins.filter { $0 != credentials.accountId },
            isAnnounceOnly: existing.isAnnounceOnly
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

    private func distributeProfileToGroupMembersIfNeeded(group: StoredGroup) async {
        if conversations.first(where: { $0.groupId == group.id })?.isRequest == true { return }
        let rev = max(myProfileRevision, 1)
        let needsProfile = group.members.filter {
            $0 != credentials.accountId && readKVInt("pfsent:\($0)") < rev
        }
        for member in needsProfile {
            await sendMyProfileIfNeeded(toPeer: member)
        }
    }

    /// One member failing doesn't stop the others. Reached members are recorded
    /// per message so a retry doesn't duplicate.
    private func transmitToGroup(
        _ content: Relay_Content_Content, group: StoredGroup, messageId: String, timestamp: Int64
    ) async throws {
        try await distributeSenderKeyIfNeeded(group: group)
        await distributeProfileToGroupMembersIfNeeded(group: group)

        let deliveredKey = "groupsent:\(messageId)"
        var delivered = Set(loadStringArray(deliveredKey))
        let targets = group.members.filter { $0 != credentials.accountId && !delivered.contains($0) }
        var firstError: Error?
        if sealedSenderEnabled {
            // Encrypt once with the sender key, then seal that ciphertext per
            // device: the relay still learns neither the sender nor that these
            // deliveries are one group send. A member we can't reach this way
            // (no access key, missing identity, stale mailbox) gets the
            // pairwise send instead.
            let payload = try content.serializedData()
            let fastPath = try? await sealedGroupFanOut(payload, group: group, members: targets, timestamp: timestamp)
            for member in targets {
                if fastPath?.contains(member) == true {
                    delivered.insert(member)
                    continue
                }
                do {
                    try await sendContent(payload, toPeer: member, clientTimestamp: timestamp)
                    delivered.insert(member)
                } catch {
                    firstError = firstError ?? error
                }
            }
        } else {
            // Encrypt once with the sender key; fan out the same ciphertext.
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

    /// Sealed-sender group fan-out (see CryptoEngine.sealedGroupEncrypt).
    /// Returns the members every device of whom accepted the message.
    private func sealedGroupFanOut(
        _ payload: Data, group: StoredGroup, members: [String], timestamp: Int64
    ) async throws -> Set<String> {
        guard let distributionId = UUID(uuidString: group.distributionId), !members.isEmpty else { return [] }
        let certificate = try await senderCertificate()
        var routes: [(member: String, mailbox: String, accessKey: Data, address: ProtocolAddress)] = []
        var skipped = Set<String>()
        for member in members {
            do {
                if knownAccessKey(member) == nil { try await refreshSessions(withPeer: member) }
                guard let accessKey = knownAccessKey(member) else { skipped.insert(member); continue }
                let devices = try await knownMailboxDevices(ofPeer: member)
                guard !devices.isEmpty else { skipped.insert(member); continue }
                for device in devices {
                    guard let mailbox = device.mailboxId, !mailbox.isEmpty else { skipped.insert(member); continue }
                    let address = try ProtocolAddress(name: member, deviceId: device.id)
                    guard try engine.hasSession(with: address) else { skipped.insert(member); continue }
                    routes.append((member, mailbox, accessKey, address))
                }
            } catch {
                skipped.insert(member)
            }
        }
        routes.removeAll { skipped.contains($0.member) }
        guard !routes.isEmpty else { return [] }

        let blobs = try engine.sealedGroupEncrypt(
            try ContentPadding.pad(payload), distributionId: distributionId,
            senderCertificate: certificate, recipients: routes.map(\.address)
        )
        var failed = skipped
        for (route, blob) in zip(routes, blobs) where !failed.contains(route.member) {
            do {
                _ = try await api.sendSealed(
                    mailboxId: route.mailbox, type: .message, content: blob,
                    accessKey: route.accessKey, ephemeral: false, clientTimestamp: timestamp
                )
            } catch {
                failed.insert(route.member)
            }
        }
        // A member with a failed device falls back to the pairwise path, which
        // re-sends to all of their devices; duplicates are dropped by id.
        return Set(routes.map(\.member)).subtracting(failed)
    }

    /// Sends our SKDM to members who lack it for the current distribution id,
    /// and again when a member's device list changes (a new device has no
    /// sender key yet). Tracked in kv as "member:deviceIds" per epoch.
    private func distributeSenderKeyIfNeeded(group: StoredGroup) async throws {
        guard let distributionId = UUID(uuidString: group.distributionId) else { return }
        let key = "skdm:\(group.id):\(group.distributionId)"
        let deviceKey: (String) -> String = { member in
            member + ":" + self.knownDevices(ofPeer: member).map { String($0.id) }.sorted().joined(separator: ",")
        }
        var sent = Set(loadStringArray(key))
        let targets = group.members.filter { $0 != credentials.accountId && !sent.contains(deviceKey($0)) }
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
                sent.insert(deviceKey(member))
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

    private static func randomInviteKey() -> Data {
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return key
    }

    /// A group id must be a random UUID that can't be mistaken for an account:
    /// group and 1:1 conversations share one key space.
    static func isValidGroupId(_ id: String, ownAccount: String) -> Bool {
        UUID(uuidString: id) != nil && id != ownAccount && id != relayOfficialAccount
    }

    private func sendGroupUpdateCustom(
        _ update: Relay_Content_GroupUpdate, group: StoredGroup,
        to recipients: [String]? = nil, includeInviteKey: Bool = true
    ) async {
        var u = update
        u.actor = credentials.accountId
        u.name = group.name
        u.revision = group.revision
        // Full roster, admins and epoch: there is no server-side group state.
        u.members = group.members
        u.admins = group.admins
        u.distributionID = group.distributionId
        if includeInviteKey, let inviteKey = groupInviteKey(group.id) { u.inviteKey = inviteKey }
        var content = Relay_Content_Content()
        content.groupUpdate = u
        content.groupID = group.id
        content.senderAccountID = credentials.accountId
        content.senderDeviceID = credentials.deviceId
        guard let data = try? content.serializedData() else { return }
        for member in recipients ?? group.members where member != credentials.accountId {
            try? await sendContent(data, toPeer: member, clientTimestamp: Int64(Date().timeIntervalSince1970 * 1000))
        }
    }

    /// Fans pre-encrypted ciphertext (e.g. sender-key) to every device of
    /// `account`, with the same mismatch retry as 1:1 sends.
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

    /// `authenticatedSender` is the identity proven by decryption (sealed-sender
    /// certificate or ratchet) and is the source of truth for authorization.
    func handleGroupUpdate(_ info: GroupUpdateInfo, authenticatedSender: String?) async {
        let existing = try? storage.messages.group(id: info.groupId)

        // 1. The claimed `actor` must be the authenticated sender.
        if let sender = authenticatedSender, !sender.isEmpty, !info.actor.isEmpty, info.actor != sender {
            log.warning("group update: actor != authenticated sender; dropping")
            return
        }
        let actor = (authenticatedSender.flatMap { $0.isEmpty ? nil : $0 }) ?? info.actor
        guard !actor.isEmpty else { return }
        // A sender whose safety number changed and hasn't been accepted can't
        // change the group: a relay posing as an admin would start here.
        guard actor == credentials.accountId || IdentityAcknowledgement.isSettled(peer: actor, storage: storage) else {
            log.warning("group update from an unaccepted safety number; dropping")
            return
        }
        // Revisions only ever step by one per change; an implausible jump would
        // overflow our own `revision + 1` later and wedge every admin action.
        guard info.revision >= 0, info.revision <= (existing?.revision ?? 0) + 100_000 else {
            log.warning("group update: implausible revision; dropping")
            return
        }

        // 2. Authorization. With no local state, trust the authenticated actor
        //    adding us. Otherwise only admins change group state, any member may
        //    leave, and a link-joiner may add only themselves by echoing the
        //    current invite capability. Legacy groups with no admins are open.
        let isBootstrap = (existing == nil)
        if isBootstrap {
            // Only accept a brand-new group from someone who is in it, that
            // includes us, and whose id can't collide with a 1:1 chat.
            guard Self.isValidGroupId(info.groupId, ownAccount: credentials.accountId),
                  info.members.contains(actor),
                  info.members.contains(credentials.accountId),
                  info.action == .create || info.action == .add
            else {
                log.warning("group update: rejected bootstrap for unknown group")
                return
            }
        }
        let actorIsAdmin = existing.map { Self.isGroupAdmin(actor, in: $0) } ?? true
        let isSelfDeparture = (info.action == .leave || info.action == .remove) && info.target == actor
            && (existing?.members.contains(actor) ?? false)
        let isValidSelfJoin = info.action == .add && info.target == actor
            && !info.inviteKey.isEmpty && groupInviteKey(info.groupId) == info.inviteKey
        guard isBootstrap || actorIsAdmin || isSelfDeparture || isValidSelfJoin else {
            log.warning("group update: \(String(describing: info.action)) from non-admin; dropping")
            return
        }
        // An admin change older than what we have (delayed or replayed) would
        // roll the roster back, e.g. re-adding someone since removed.
        if let existing, !isSelfDeparture, !isValidSelfJoin, info.revision < existing.revision {
            log.warning("group update: stale revision; dropping")
            return
        }

        // Store the invite capability only from authorized senders, never from
        // a self-join echo.
        if !info.inviteKey.isEmpty, isBootstrap || actorIsAdmin {
            setGroupInviteKey(info.groupId, info.inviteKey)
        }
        // Silent capability broadcast: nothing else to apply.
        if info.action == .unknown { return }

        // 3. We were removed by an admin.
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
        if isSelfDeparture, let existing {
            // Never adopt the sender's lists here: self-departure bypasses the
            // admin check, so that would let any member make themselves sole
            // admin and reroute the group.
            newMembers = existing.members.filter { $0 != actor }
            newAdmins = existing.admins.filter { $0 != actor }
            newName = existing.name
            distributionId = existing.distributionId
        } else if isValidSelfJoin && !isBootstrap && !actorIsAdmin, let existing {
            // A link-joiner may only add themselves; never take a non-admin's
            // roster, admins, name or epoch.
            newMembers = existing.members.contains(actor) ? existing.members : existing.members + [actor]
            newAdmins = existing.admins
            newName = existing.name
            distributionId = existing.distributionId
        } else {
            // Authorized sender: trust the full lists, falling back to the delta
            // when only a target is given.
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
            newAdmins = (info.admins.isEmpty ? (existing?.admins ?? [actor]) : info.admins)
                .filter { newMembers.contains($0) }
            newName = info.name.isEmpty ? (existing?.name ?? "") : info.name
            // Adopt a rotated epoch so our next send uses a key a removed member
            // can't read.
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
            // Added to a new group by someone we've never chatted with: a request.
            if isBootstrap, actor != credentials.accountId, !hasAcceptedChat(with: actor),
               let convoId = try? storage.messages.groupConversationId(groupId: info.groupId) {
                try? storage.messages.setConversationAccepted(convoId, accepted: false)
            }
            refreshConversations()
            if let convoId = try? storage.messages.groupConversationId(groupId: info.groupId) {
                refreshActiveMessages(ifShowing: convoId)
            }
            // Names arrive via profiles and certificates, never a relay lookup.
            if newMembers.contains(credentials.accountId),
               let stored = try? storage.messages.group(id: info.groupId) {
                await distributeProfileToGroupMembersIfNeeded(group: stored)
            }
            if let line = systemLine(for: info) { insertSystemLine(line, inGroup: info.groupId) }
            // Non-sealed groups use sender keys: share ours with new members and
            // mint a fresh one after an epoch rotation.
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

    /// Invite capability for link self-joins, stored in kv.
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
        var content = Relay_Content_Content()
        content.receipt.type = type
        content.receipt.messageTimestamps = timestamps
        if let groupId { content.groupID = groupId }
        do {
            try await sendContent(
                try content.serializedData(),
                toPeer: account,
                clientTimestamp: Int64(Date().timeIntervalSince1970 * 1000),
                silent: true
            )
        } catch {
            log.warning("receipt send failed: \(PrivacyRedactor.error(error))")
        }
    }

    /// On a device mismatch, re-fetches bundles and retries once.
    private func sendContent(
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
    private func recipientSupportsSealed(_ account: String) async -> Bool {
        if knownAccessKey(account) != nil { return true }
        try? await refreshSessions(withPeer: account)
        return knownAccessKey(account) != nil
    }

    /// Unlike the WebSocket path there's no device-mismatch verdict, so this
    /// relies on the local device list (kept current by `DeviceListChanged` and
    /// bundle refreshes).
    private func sendContentSealed(
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

    private func knownAccessKey(_ account: String) -> Data? {
        if let key = peerAccessKeys[account] { return key }
        guard let data = (try? storage.database.query(
            "SELECT value FROM kv WHERE key = ?", [.text("ak:\(account)")]
        ).first?.first?.data) ?? nil, data.count == 32 else { return nil }
        peerAccessKeys[account] = data
        return data
    }

    private func rememberAccessKey(_ key: Data?, for account: String) {
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

    private func refreshSessions(withPeer account: String) async throws {
        let bundles: [PeerPreKeyBundle]
        // With an access key the fetch is anonymous; a 403 means it was rotated
        // and we fall back to the signed fetch. For someone new, look up their
        // certificate username in the blinded directory to get the key first.
        if account != credentials.accountId, knownAccessKey(account) == nil,
           let username = cachedUsername(account),
           let resolved = try? await resolveAccount(username: username), resolved != account {
            log.info("directory username now belongs to a different account; using the signed fetch")
        }
        if account != credentials.accountId, let known = knownAccessKey(account),
           let anonymous = try await fetchBundlesAnonymously(account, accessKey: known) {
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

    // MARK: - Read state

    func openConversation(_ conversationId: String) {
        activeConversationId = conversationId
        activeMessages = []
        messagesLoadedConversationId = nil
        cachedActiveGroup = group(for: conversationId)  // avoids per-message DB queries
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
                await distributeProfileToGroupMembersIfNeeded(group: group)
            } else if let peer = resolvedPeerAccount(for: conversationId) {
                // Pre-warm the sealed-send path so the first message doesn't chain
                // a bundle fetch before sending.
                if knownAccessKey(peer) == nil { try? await refreshSessions(withPeer: peer) }
                _ = try? await senderCertificate()
                await sendMyProfileIfNeeded(toPeer: peer)
            }
        }
    }

    func closeConversation(id: String) {
        // SwiftUI fires the new view's onAppear before the old onDisappear.
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

    // Intentionally a no-op: polling the relay for presence would tell it whose
    // status we watch.
    private func startPresencePolling(peer: String) {}
    private func stopPresencePolling() {}

    private func postMentionNotification(body: String, senderAccount: String) {
        let content = UNMutableNotificationContent()
        let preview = NotificationPreviewSetting.current
        content.title = "You were mentioned"
        content.body = preview.showsContent ? body
            : (preview.showsSenderName ? "by \(displayName(forAccount: senderAccount))" : "")
        content.sound = .default
        let id = "mention-\(senderAccount)-\(Int64(Date().timeIntervalSince1970 * 1000))"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil)
        )
    }

    private func markVisibleMessagesRead(in conversationId: String) async {
        guard let messages = try? storage.messages.messages(in: conversationId) else { return }
        let unread = messages.filter { !$0.isOutgoing && $0.status == .received }
        // Mark read locally first and unconditionally. The badge uses read_at,
        // which can disagree with per-message status, and a slow or interrupted
        // receipt send must not leave the chat unread.
        for message in unread {
            try? storage.messages.updateStatus(messageId: message.id, status: .read)
        }
        try? storage.messages.markConversationRead(conversationId)
        refreshConversations()

        // System lines and the Relay chat have nobody to receipt.
        let receiptable = unread.filter { $0.senderAccount != Self.systemSender }
        let peer = try? peerAccount(for: conversationId)
        let hasRealPeer = peer != relayOfficialAccount && peer != noteToSelfAccount
        guard sendReadReceipts, hasRealPeer, !receiptable.isEmpty else { return }
        if let group = group(for: conversationId) {
            let byAuthor = Dictionary(grouping: receiptable) { $0.senderAccount ?? "" }
            for (author, msgs) in byAuthor where !author.isEmpty && author != credentials.accountId {
                await sendReceipt(.read, timestamps: msgs.map(\.timestamp), toPeer: author, groupId: group.id)
            }
        } else if let peer {
            await sendReceipt(.read, timestamps: receiptable.map(\.timestamp), toPeer: peer)
        }
    }

    /// Messages the NSE stored while backgrounded are now on screen.
    func markActiveConversationReadOnForeground() {
        guard let conversationId = activeConversationId else { return }
        Task { await markVisibleMessagesRead(in: conversationId) }
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
        // Migrate the old boolean mute set to forever entries.
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

    /// Holds outbound messages for a short random delay so observers can't tie
    /// a send to the moment the user tapped Send.
    var sendJitterEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "relay.sendJitter") }
        set { UserDefaults.standard.set(newValue, forKey: "relay.sendJitter") }
    }

    /// Sends via the unauthenticated `/v1/messages/sealed` endpoint; the sender
    /// identity travels inside the encrypted blob with a relay-minted certificate.
    var sealedSenderEnabled: Bool {
        // Mandatory and not user-configurable.
        get { true }
        set { }
    }

    /// Opt-in ciphertext-in-push. Off by default, so pushes are a content-free
    /// wake and APNs carries no message data. When on, the relay embeds the
    /// encrypted envelope to skip a fetch. Mirrored to the server per device.
    var pushIncludeContent: Bool {
        get { UserDefaults.standard.bool(forKey: "relay.pushIncludeContent") }
        set {
            UserDefaults.standard.set(newValue, forKey: "relay.pushIncludeContent")
            Task { try? await self.api.setPushIncludeContent(newValue) }
        }
    }

    /// Call after a username change: the certificate carries the username.
    func invalidateSenderCertificate() {
        cachedSenderCert = nil
    }

    private func senderCertificate() async throws -> Data {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if let cert = cachedSenderCert, cert.expiresAt - nowMs > 86_400_000 {
            return cert.data
        }
        let fetched = try await api.deliveryCertificate()
        cachedSenderCert = (fetched.certificate, fetched.expiresAt)
        return fetched.certificate
    }

    /// Up to ~5s when send jitter is enabled.
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
        let previous = conversations.first(where: { $0.id == conversationId })?.disappearingSeconds ?? 0
        do {
            try storage.messages.setDisappearingSeconds(conversationId, seconds: seconds)
            if seconds != previous {
                // The timer travels with each message, so note the change in the thread.
                let text = seconds == 0
                    ? "You turned off disappearing messages"
                    : "You set disappearing messages to \(Self.durationLabel(seconds))"
                insertSystemLine(text, conversationId: conversationId)
            }
            refreshConversations()
        } catch {
            log.error("set disappearing messages failed: \(PrivacyRedactor.error(error))")
        }
    }

    private static func durationLabel(_ seconds: Int64) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.weekOfMonth, .day, .hour, .minute, .second]
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds) seconds"
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

    /// Groups use the admin-set flag; DMs hide if either side asks to.
    func effectiveScreenHidden(_ conversationId: String) -> Bool {
        if let group = group(for: conversationId) { return group.screenSecurity }
        guard let conv = conversations.first(where: { $0.id == conversationId }) else { return true }
        if conv.peerAccount == noteToSelfAccount || conv.peerAccount == relayOfficialAccount { return false }
        return conv.screenSecurity || conv.peerScreenSecurity
    }

    func myScreenSecurityPref(_ conversationId: String) -> Bool {
        conversations.first { $0.id == conversationId }?.screenSecurity ?? true
    }

    /// Synced to the peer so both sides agree on the effective state.
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

    /// Admin-only.
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

    /// Sent regardless of the hide setting.
    func sendScreenshotAlert(conversationId: String) {
        guard let conv = conversations.first(where: { $0.id == conversationId }) else { return }
        if conv.peerAccount == noteToSelfAccount || conv.peerAccount == relayOfficialAccount { return }
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

    func deleteViewOnceAttachment(_ attachment: StoredAttachment, in conversationId: String) {
        attachmentStore.delete(attachment.id)
        // Dropping the row discards the pointer and key, so the blob can't be
        // re-fetched and the bubble shows "Opened".
        try? storage.database.run("DELETE FROM attachments WHERE id = ?", [.text(attachment.id)])
        refreshActiveMessages(ifShowing: conversationId)
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

    /// For ConversationListView's multi-select toolbar.
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

    @discardableResult
    func ensureNoteToSelf() async -> String {
        guard let me = username else { return "" }
        return (try? await startConversation(username: me)) ?? ""
    }

    // MARK: - Official Relay account

    /// Local and read-only. Posts a welcome on first creation.
    @discardableResult
    func ensureRelayAccount() -> String {
        guard let id = try? storage.messages.conversation(
            withPeer: relayOfficialAccount, username: Self.relayOfficialUsername
        ) else { return "" }
        // The Relay chat holds only Relay notices; strip stray system lines.
        if let existing = try? allMessages(in: id) {
            for m in existing where m.senderAccount == Self.systemSender {
                try? storage.messages.deleteMessage(id: m.id)
            }
        }
        if !UserDefaults.standard.bool(forKey: "relay.official.welcomed") {
            UserDefaults.standard.set(true, forKey: "relay.official.welcomed")
            insertRelayMessage(
                "Welcome to Relay 👋\n\nI'll let you know about important account activity here — new devices, sign-ins, username changes, account recovery and backups. You can't reply to this chat.",
                conversationId: id)
        }
        // Undo a legacy auto-pin once; after that pinning is the user's choice.
        if UserDefaults.standard.bool(forKey: "relay.official.pinned"),
           !UserDefaults.standard.bool(forKey: "relay.official.autoPinUndone") {
            UserDefaults.standard.set(true, forKey: "relay.official.autoPinUndone")
            setConversationPinned(id, pinned: false)
        }
        refreshConversations()
        refreshActiveMessages(ifShowing: id)
        return id
    }

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

    /// Read when every other member has read it, delivered when all have
    /// received it, otherwise the message's own status.
    func groupAggregateStatus(for message: StoredMessage, in conversationId: String) -> MessageStatus {
        // Cached group avoids DB queries per message during render.
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

    /// For the info sheet, sorted read-first.
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

    // MARK: - Safety-number verification

    struct SafetyNumberChangedError: Error {
        let peer: String
    }

    struct PeerVerification {
        let safetyNumber: SafetyNumber
        let state: VerificationState
        /// The peer's devices present different identity keys. The safety number
        /// covers only one, so verification is refused.
        var hasConflictingKeys = false
    }

    private func hasConflictingIdentityKeys(_ peer: String) -> Bool {
        ((try? storage.signalStore.identityKeys(address: peer).count) ?? 0) > 1
    }

    /// Nil until a session/identity exists.
    func peerVerification(for conversationId: String) -> PeerVerification? {
        guard let peer = resolvedPeerAccount(for: conversationId) else { return nil }
        do {
            guard let deviceId = try storage.signalStore.newestIdentityDeviceId(address: peer),
                  let safetyNumber = try engine.safetyNumber(withPeer: peer, deviceId: deviceId) else { return nil }
            var state = try storage.signalStore.verificationState(address: peer)
            if state == .unverified, try isIdentityChangeAwaitingAcknowledgement(forPeer: peer) {
                state = .changed
            }
            let conflicting = hasConflictingIdentityKeys(peer)
            if conflicting { state = .changed }
            return PeerVerification(safetyNumber: safetyNumber, state: state, hasConflictingKeys: conflicting)
        } catch {
            log.error("safety number failed: \(PrivacyRedactor.error(error))")
            return nil
        }
    }

    /// Clearing also dismisses a pending safety-number-changed warning.
    func setVerified(_ verified: Bool, conversationId: String) {
        guard let peer = resolvedPeerAccount(for: conversationId) else { return }
        // Would also approve devices the safety number doesn't cover.
        if verified, hasConflictingIdentityKeys(peer) { return }
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

    /// When a peer's removed devices still have stored keys (which makes the
    /// safety number look conflicting), re-fetches their current devices so the
    /// stale keys are dropped.
    func refreshPeerIdentitiesIfConflicting(conversationId: String) async {
        guard let peer = resolvedPeerAccount(for: conversationId), hasConflictingIdentityKeys(peer) else { return }
        try? await refreshSessions(withPeer: peer)
        refreshConversations()
    }

    /// Marks the peer verified if the scanned encoding matches.
    func verifyScanned(_ encoding: Data, conversationId: String) -> Bool {
        guard let peer = resolvedPeerAccount(for: conversationId) else { return false }
        guard !hasConflictingIdentityKeys(peer) else { return false }
        do {
            guard let deviceId = try storage.signalStore.newestIdentityDeviceId(address: peer) else { return false }
            let matches = try engine.verifyScannedSafetyNumber(encoding, withPeer: peer, deviceId: deviceId)
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
        IdentityAcknowledgement.key(forPeer: peer)
    }

    private func guardIdentityReplacement(_ identityData: Data, peer: String, address: ProtocolAddress) throws {
        let incomingIdentity = try IdentityKey(bytes: identityData)
        // Trusted: the same key for a known device, or for a new device one of
        // the keys this account already uses. Anything else, including a new
        // device with a new key (what a compromised relay would inject), is a
        // safety-number change.
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

    /// True if any of the peer's identity keys is unacknowledged (a changed key
    /// or an unexpected device).
    private func isIdentityChangeAwaitingAcknowledgement(forPeer peer: String) throws -> Bool {
        let current = Set(try storage.signalStore.identityKeys(address: peer))
        guard !current.isEmpty else { return false }
        guard let acknowledged = try acknowledgedIdentities(forPeer: peer) else {
            // TOFU on first contact.
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

    /// Also reads the legacy single-key format.
    private func acknowledgedIdentities(forPeer peer: String) throws -> Set<Data>? {
        try IdentityAcknowledgement.acknowledged(forPeer: peer, storage: storage)
    }

    private func noteBlockedSafetyWarning(peer: String) {
        guard let conversationId = try? storage.messages.conversation(withPeer: peer, username: nil) else { return }
        blockedSafetyWarningConversationId = conversationId
        refreshConversations()
    }

    // MARK: - Reactions

    /// Sends a control message to the 1:1 peer or every other group member.
    /// Non-ephemeral content is mirrored to our own devices.
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
                  peer != noteToSelfAccount, peer != relayOfficialAccount,
                  !(ephemeral && isBlocked(peer)) {
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
        // In a group the conversation's peer is the group id, not the author.
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

    /// This device only; no tombstone is sent.
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

    /// Blob files live in the App Group container; the DB tracks only metadata.
    private func reapAttachmentBlobs(messageId: String) {
        let ids = (try? storage.database.query(
            "SELECT id FROM attachments WHERE message_id = ?", [.text(messageId)]
        )) ?? []
        for row in ids {
            if let id = row.first?.string { attachmentStore.delete(id) }
        }
    }

    static let unsendWindow: TimeInterval = 24 * 60 * 60

    /// Own, non-deleted messages within the unsend window.
    func canUnsend(_ message: StoredMessage) -> Bool {
        guard message.isOutgoing, !message.isDeleted else { return false }
        let sentAt = Date(timeIntervalSince1970: Double(message.timestamp) / 1000)
        return Date().timeIntervalSince(sentAt) < Self.unsendWindow
    }

    /// Leaves a tombstone locally and on the peer. Queued like a normal message
    /// so it reaches an offline peer.
    func unsend(_ message: StoredMessage) {
        let conversationId = message.conversationId
        guard canUnsend(message) else { return }
        do {
            reapAttachmentBlobs(messageId: message.id)
            try storage.messages.markDeleted(id: message.id)
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

    func editMessage(_ message: StoredMessage, newBody: String) {
        let conversationId = message.conversationId
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            try storage.messages.editMessage(id: message.id, newBody: newBody)
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

    // MARK: - Typing indicators

    /// Conversations we've told "started typing" and not yet "stopped".
    private var typingStartedSent: Set<String> = []

    func sendTyping(_ action: Relay_Content_TypingMessage.Action, in conversationId: String) {
        if isMessageRequest(conversationId) { return }
        // When typing indicators are off, still send .stopped for a .started
        // that went out before the setting changed.
        if !PrivacyPreferences.sendTypingEnabled {
            guard action == .stopped, typingStartedSent.remove(conversationId) != nil else { return }
        } else if action == .started {
            typingStartedSent.insert(conversationId)
        } else {
            typingStartedSent.remove(conversationId)
        }
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

    /// Lets a group chat name who is typing.
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
        // Typing frames are never queued, so a "stopped" can be lost.
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

    // MARK: - Peer device bookkeeping

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

    // Unencrypted list in App Group storage so the Share Extension can show a
    // picker without the database keys.
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
                isGroup: conv.groupId != nil
            )
        }
        ShareBridge.writeConversations(summaries)
        for conv in conversations {
            if let data = peerAvatarData(forAccount: conv.peerAccount) {
                ShareBridge.writeAvatar(data, forConversationId: conv.id)
            }
        }
    }

    // Sends a PendingShare left by the Share Extension and returns its
    // conversation id for navigation.
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

    // Feeds share-sheet and Siri suggestions.
    private func donateInteraction(peerAccount account: String, conversationId: String) {
        // Siri's store is outside the encrypted DB, so skip panic-hidden chats.
        guard !PanicModeManager.hiddenConversationIdsSnapshot().contains(conversationId) else { return }
        let name = displayName(forAccount: account)
        // Identify the person by conversation id, not account id: these
        // donations live in Siri's store, outside the app.
        let handle = INPersonHandle(value: conversationId, type: .unknown)
        let avatarImage = peerAvatarData(forAccount: account).flatMap { INImage(imageData: $0) }
        let person = INPerson(
            personHandle: handle,
            nameComponents: nil,
            displayName: name,
            image: avatarImage,
            contactIdentifier: nil,
            customIdentifier: conversationId
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
        interaction.groupIdentifier = conversationId
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
        // The connection loop refreshes once at queueDrained.
        guard !isDrainingQueue else { return }
        // Coalesce bursts into one deferred update; the query runs off-main.
        guard !conversationsRefreshScheduled else {
            // The in-flight query may predate this change; run once more after.
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
            // Chats hidden by Panic Mode don't count toward the badge.
            let hidden = PanicModeManager.hiddenConversationIdsSnapshot()
            let unread = (try? result.get())?.reduce(0) { hidden.contains($1.id) ? $0 : $0 + $1.unreadCount } ?? 0
            // Gather Spotlight inputs on the main actor, index off-main so image
            // decoding doesn't hitch the UI.
            let indexItems: [SpotlightIndexer.IndexItem] = await MainActor.run { [weak self] in
                guard let self, self.conversationsRefreshVersion == version else { return [] }
                self.conversationsRefreshScheduled = false
                if self.conversationsRefreshDirty {
                    self.conversationsRefreshDirty = false
                    self.refreshConversations()
                }
                // On failure keep conversations, so injected entries like Note to
                // Self stay visible.
                guard case .success(let convs) = result else { return [] }
                self.conversations = convs
                self.updateShareConversationList()
                self.scheduleAccountStorageUploadIfChanged()
                self.scheduleSiriPreviewWrite()
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
