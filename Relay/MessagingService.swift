//
//  MessagingService.swift
//  Relay
//
//  Ties CryptoCore, SecureStorage and RelayKit together: the connection loop,
//  the incoming-envelope pipeline, receipts, and per-device fan-out.
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
struct GroupInvitePayload: Codable {
    let groupId: String
    let name: String
    let members: [String]
    let distributionId: String
    let inviteKey: Data
    /// Optional for links made by older builds.
    let admins: [String]?
    /// The group's revision when the link was made (optional for older links).
    /// A joiner starting from 1 would have its later changes dropped as stale.
    var revision: Int64? = nil
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
    let session: URLSession

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
    var activeMessages: [StoredMessage] = []
    /// How many of the newest messages the open chat loads; grows with
    /// "Load Earlier Messages".
    var activeMessageLimit = MessagingService.messagePageSize
    /// Whether the open chat has messages older than the ones loaded.
    var hasEarlierMessages = false
    static let messagePageSize = 100
    /// Bumped on every reload of the open chat, including ones that change
    /// no message (a poll vote, a reaction), for views that read other tables.
    private(set) var activeMessagesRevision = 0
    var activeConversationId: String?
    /// Set to the conversation ID whose messages have just finished loading.
    /// Lets ChatView distinguish "still loading" from "genuinely empty".
    var messagesLoadedConversationId: String? = nil
    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var authenticationExpired = false
    /// Per-conversation so the chat list can show typing for chats that aren't open.
    var typingConversations: Set<String> = []
    /// Mute expiry per conversation: Int64.max = forever, positive = Unix ms expiry.
    var muteExpiries: [String: Int64] = [:]
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
    let keychain: KeychainSecureStore
    let engine: CryptoEngine
    private let processor: EnvelopeProcessor
    let api: RelayAPIClient
    private let maintainer = PreKeyMaintainer()
    let attachmentStore = AttachmentBlobStore(appGroupId: AppModel.appGroupId)
    private let allocator: KVPreKeyIdAllocator
    var socket: RelayWebSocket?
    private var connectionTask: Task<Void, Never>?
    /// HTTP/3 queue polling for when the WebSocket can't connect (congested
    /// networks). The WebSocket stays the primary path.
    private var pollTask: Task<Void, Never>?
    /// Whether the WebSocket is up and draining; gates the poll fallback. Not the
    /// same as `connectionState`, which goes `.connected` once the server is
    /// reachable over QUIC, even without the TCP socket.
    private var socketLive = false
    private var expireTask: Task<Void, Never>?
    var typingResetTasks: [String: Task<Void, Never>] = [:]
    let log = Logger(subsystem: "com.relaytextingapp.Relay", category: "messaging")

    // Caches to keep DB queries out of SwiftUI render passes.
    private var nameCache: [String: String] = [:]
    private var avatarCache: [String: Data?] = [:]
    var cachedActiveGroup: StoredGroup?? = nil  // nil = uncached; .some(nil) = confirmed 1:1
    // Coalesces rapid refresh calls into one deferred update.
    private var conversationsRefreshScheduled = false
    private var conversationsRefreshVersion: Int = 0
    // Suppresses per-envelope refreshes while draining the queue on connect.
    // Starts false so the init-time refreshConversations() populates App Group storage.
    private var isDrainingQueue = false
    /// Persisted in the encrypted kv table.
    var blockedAccounts: Set<String> = []
    /// Conversation that tried to send to a replacement identity key before
    /// the user acknowledged the new safety number.
    var blockedSafetyWarningConversationId: String?
    private var pathMonitor: NWPathMonitor?
    private(set) var isOnWifi: Bool = true

    // MARK: Sealed sender
    /// This device's cached sealed-sender delivery certificate and its expiry
    /// (ms). Refreshed a day before it lapses.
    var cachedSenderCert: (data: Data, expiresAt: Int64)?
    /// Per-account sealed-sender access keys, captured when we fetch prekey
    /// bundles. Needed to address a recipient on the unauthenticated path.
    var peerAccessKeys: [String: Data] = [:]

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
    /// What to do about a device the user doesn't recognise. Unlinking alone
    /// isn't enough: a linked device holds the account's security key.
    static let untrustedDeviceAdvice = "If this wasn't you, unlink it in Profile → Linked Devices, then sign in to your account again on this iPhone so the account gets a new security key, and check your passkeys, recovery key and account password."

    func shutDown() {
        isShutDown = true
        LocationShareManager.shared.stopAll()
        siriPreviewTask?.cancel()
        siriPreviewTask = nil
        stop()
    }

    func start() {
        guard connectionTask == nil, !isShutDown else { return }
        isStopped = false
        Task { await refreshDemoStatus() }
        if !didSweepInterruptedSends {
            // Only on the first start of this process: nothing can be mid-send
            // yet, so anything still "sending" was interrupted by a kill.
            didSweepInterruptedSends = true
            failInterruptedSends()
            // Older builds donated every chat; suggestions are now opt-in.
            if !PrivacyPreferences.shareSuggestionsEnabled { INInteraction.deleteAll(completion: nil) }
        }
        loadDirectoryDecoySeed()
        connectionTask = Task { await runConnectionLoop() }
        pollTask = Task { [weak self] in await self?.runQueuePollLoop() }
        Task { [weak self] in await self?.publishDeviceLabel(force: false) }
        startPathMonitor()
        // Housekeeping once per start: dedup claims, orphaned files, and
        // App Group files written before they were sealed.
        try? storage.messages.pruneProcessedEnvelopes()
        sweepAttachmentFiles()
        ShareBridge.sealLegacyFiles()
        expireTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await MainActor.run {
                    guard let self else { return }
                    // Notifications of expired messages go too.
                    let now = Int64(Date().timeIntervalSince1970 * 1000)
                    let expired = (try? self.storage.database.query(
                        "SELECT conversation_id, id FROM messages WHERE expires_at IS NOT NULL AND expires_at <= ?",
                        [.integer(now)]
                    )) ?? []
                    let affected = Set(expired.compactMap { $0.first?.string })
                    _ = try? self.storage.messages.deleteExpiredMessages(now: now)
                    self.removeDeliveredNotifications(
                        forConversations: affected, messageIds: Set(expired.compactMap { $0.count > 1 ? $0[1].string : nil }))
                    if !affected.isEmpty { self.sweepAttachmentFiles() }
                    self.refreshConversations()
                    // The open chat shows its own copy of the messages; drop the
                    // expired ones from the screen too.
                    if let active = self.activeConversationId, affected.contains(active) {
                        self.refreshActiveMessages(ifShowing: active)
                    }
                }
                await self?.flushDueScheduledMessages()
            }
        }
    }

    /// Removes delivered notifications in these chats (their threads), so a
    /// message that expired, was unsent or edited doesn't linger on the lock
    /// screen with its old text. With `messageIds`, a notification that names
    /// its message goes only if it's one of them; ones that don't say go too.
    func removeDeliveredNotifications(forConversations ids: Set<String>, messageIds: Set<String>? = nil) {
        guard !ids.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let stale = delivered.filter {
                guard ids.contains($0.request.content.threadIdentifier) else { return false }
                guard let messageIds, let shown = $0.request.content.userInfo["relayMessageId"] as? String else { return true }
                return messageIds.contains(shown)
            }
            .map(\.request.identifier)
            if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
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

    /// Set by stop(), cleared by start(): envelopes already chained when the
    /// app stops are left for the relay to deliver again.
    private var isStopped = false

    func stop() {
        isStopped = true
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
                    Task {
                        await self.upgradeRecoveryKeyHashIfNeeded()
                        await self.noteAccountPasswordNeedsUpdateIfNeeded()
                        await self.noteNoWayBackInIfNeeded()
                    }
                    if !didRepublishKeysThisLaunch {
                        didRepublishKeysThisLaunch = true
                        do {
                            try await maintainer.republishSignedPreKey(api: api, engine: engine, allocator: allocator)
                            try? storage.signalStore.pruneReplacedPreKeys()
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
                        // Every other device says so, not just the one that
                        // linked it (where a notice is easy to delete).
                        postRelayNotice("A new device (device \(change.deviceId)) was added to your account. \(Self.untrustedDeviceAdvice)")
                    }
                case .accountNotice(let kind, let timeMs):
                    noteAccountChange(kind: kind, timeMs: timeMs)
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

    /// Waits (up to `timeout`) for the envelope being processed, if any. The
    /// processor holds a file lock in the shared container while it works, and
    /// iOS kills a suspended app holding one (0xdead10cc), so the app waits for
    /// this before ending its background time.
    func waitForInFlightProcessing(timeout: Duration = .seconds(3)) async {
        guard let chain = envelopeChain else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await chain.value }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
    }

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
        // Stopped (going to the background): don't start on more envelopes,
        // which would take the shared-container lock just as the app is
        // suspended. No ack, so the relay delivers it again.
        guard !isStopped else { return }
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
        if result.removesNotifications, let conversationId = result.conversationId {
            removeDeliveredNotifications(forConversations: [conversationId],
                                         messageIds: result.removedMessageId.map { [$0] })
        }
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
                    postMentionNotification(body: body, senderAccount: result.peerAccount ?? "", conversationId: conversationId)
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
                // Off the envelope chain: an avatar download (up to 26 MB) must
                // not hold up the call signals queued behind it.
                Task { await self.applyPeerProfile(profile) }
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
    func hasAcceptedChat(with account: String) -> Bool {
        conversations.contains { !$0.isGroup && $0.peerAccount == account && !$0.isRequest }
    }

    /// Who may ring us: someone we've accepted a chat with, or a member of a
    /// group we've accepted. Anyone else is a message request.
    func isCallAllowed(from account: String) -> Bool {
        // From the database, not `conversations`: that list may not be loaded
        // yet (a cold launch from a VoIP push) or may lag a queue drain.
        let db = storage.database
        if let rows = try? db.query(
            "SELECT accepted FROM conversations WHERE peer_account = ? AND group_id IS NULL", [.text(account)]
        ), let accepted = rows.first?.first?.int64, accepted != 0 {
            return true
        }
        // No accepted 1:1 chat: a member of an accepted group we're still in
        // (someone in our group may also have a pending 1:1 request).
        let groupIds = ((try? db.query(
            "SELECT group_id FROM conversations WHERE group_id IS NOT NULL AND accepted = 1"
        )) ?? []).compactMap { $0.first?.string }
        return groupIds.contains { gid in
            guard let members = (try? storage.messages.group(id: gid))?.members else { return false }
            return members.contains(account) && members.contains(credentials.accountId)
        }
    }

    /// The 1:1 chat with `account`, read from the database.
    func oneToOneConversationId(withPeer account: String) -> String? {
        (try? storage.database.query(
            "SELECT id FROM conversations WHERE peer_account = ? AND group_id IS NULL", [.text(account)]
        ).first?.first?.string) ?? nil
    }

    /// A call from a message request doesn't ring; it leaves a note in the
    /// request instead (never in an accepted chat).
    func noteCallFromRequest(_ account: String) {
        guard !isBlocked(account),
              let conversationId = try? storage.messages.conversation(withPeer: account, accepted: false),
              (try? storage.messages.isAccepted(conversationId: conversationId)) == false
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
            if group(for: conversationId) != nil {
                // A group send stops at a member whose key changed; the group
                // thread names them (groupMembersWithChangedSafetyNumbers).
                if !groupMembersWithChangedSafetyNumbers(conversationId).isEmpty {
                    blockedSafetyWarningConversationId = conversationId
                }
            } else if let safetyError = error as? SafetyNumberChangedError {
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
    /// Runs `work` after a random delay, under a background task so the delay
    /// can't strand it. Receipts and sync copies sent the instant a message
    /// arrives or leaves would let anyone watching the relay pair the two
    /// sealed sends by timing; the jitter blurs that link. Returns at once.
    private struct DeferredSend {
        var due: Date
        let work: @MainActor () async -> Void
    }
    private var deferredSends: [DeferredSend] = []
    private var deferredRunner: Task<Void, Never>?
    private var deferredBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// Queues `work` to run after a random delay. The queue runs in order, so
    /// sync copies can't overtake each other (an unsend arriving before its
    /// message would be lost on the other device). Runs under a background
    /// task; going to the background or running out of time sends everything
    /// at once (flushDeferredSends).
    func afterTimingJitter(seconds range: ClosedRange<Double>, _ work: @escaping @MainActor () async -> Void) {
        deferredSends.append(DeferredSend(due: Date().addingTimeInterval(Double.random(in: range)), work: work))
        guard deferredRunner == nil else { return }
        if deferredBackgroundTask == .invalid {
            deferredBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "relay-deferred-sends") { [weak self] in
                // Out of time: send the rest now, then let go.
                self?.flushDeferredSends()
                self?.endDeferredBackgroundTask()
            }
        }
        deferredRunner = Task { @MainActor [weak self] in
            while let self, !self.isShutDown, let next = self.deferredSends.first {
                if next.due > Date() {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                self.deferredSends.removeFirst()
                await next.work()
            }
            self?.deferredRunner = nil
            self?.endDeferredBackgroundTask()
        }
    }

    /// Sends everything waiting without its delay (app going to the background).
    func flushDeferredSends() {
        let now = Date()
        for i in deferredSends.indices { deferredSends[i].due = now }
    }

    private func endDeferredBackgroundTask() {
        guard deferredBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(deferredBackgroundTask)
        deferredBackgroundTask = .invalid
    }

    /// Receipts waiting to go out, merged per recipient so a burst of messages
    /// gets one receipt rather than one each.
    struct ReceiptKey: Hashable {
        let type: Relay_Content_ReceiptMessage.TypeEnum
        let peer: String
        let groupId: String?
    }
    var pendingReceipts: [ReceiptKey: [Int64]] = [:]

    func sendSyncToOwnDevices(
        content: Relay_Content_Content,
        peer: String,
        timestamp: Int64
    ) async {
        afterTimingJitter(seconds: 2...12) { [weak self] in
            await self?.sendSyncToOwnDevicesNow(content: content, peer: peer, timestamp: timestamp)
        }
    }

    private func sendSyncToOwnDevicesNow(
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
        // Peers would blank it anyway (ProfileText.name).
        guard !trimmed.isEmpty, trimmed != myDisplayName, !ReservedNames.isReserved(trimmed) else { return }
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
    func sendMyProfileIfNeeded(toPeer account: String) async {
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
        guard profileNeedsSending(to: account) else { return }
        let rev = max(myProfileRevision, 1)
        let accessKey = ownAccessKey()
        do {
            var content = Relay_Content_Content()
            content.profile.displayName = myDisplayName ?? ""
            content.profile.timestamp = rev
            if let accessKey { content.profile.accessKey = accessKey }
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
            if let accessKey { writeKVInt("pfak:\(account)", Self.accessKeyTag(accessKey)) }
        } catch {
            log.error("profile send failed: \(PrivacyRedactor.error(error))")
        }
    }

    /// Sent at least once (revision 1) even with nothing set: this is how peers
    /// learn our username without asking the relay who an account is. Re-sent
    /// at the same revision when the peer hasn't had our current access key.
    func profileNeedsSending(to account: String) -> Bool {
        if readKVInt("pfsent:\(account)") < max(myProfileRevision, 1) { return true }
        guard let accessKey = ownAccessKey() else { return false }
        return readKVInt("pfak:\(account)") != Self.accessKeyTag(accessKey)
    }

    /// Keychain item holding our sealed-sender access key (AppModel creates and
    /// publishes it).
    static let accessKeySecretName = "relay-access-key"

    /// Our access key, carried in profile updates so contacts can fetch our
    /// prekey bundles anonymously. Nil until AppModel has created it. Cached,
    /// since a group send checks it once per member.
    private func ownAccessKey() -> Data? {
        if let cachedOwnAccessKey { return cachedOwnAccessKey }
        guard let key = try? keychain.loadSecret(for: Self.accessKeySecretName), key.count == 32 else { return nil }
        cachedOwnAccessKey = key
        return key
    }
    @ObservationIgnored private var cachedOwnAccessKey: Data?

    /// Short tag recording which access key a peer last got. Not secret: kv is
    /// encrypted at rest, and it only has to tell a rotated key from the old one.
    private static func accessKeyTag(_ key: Data) -> Int64 {
        Int64(bitPattern: SHA256.hash(data: key).prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
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
        // Taken even when the rest of the profile is stale: peers re-send the
        // same revision to hand over a new access key.
        if let accessKey = profile.accessKey, profile.account != credentials.accountId,
           accessKey != knownAccessKey(profile.account) {
            rememberAccessKey(accessKey, for: profile.account)
        }
        let existing = (try? storage.messages.peerProfile(account: profile.account)) ?? nil
        if let existing, existing.revision >= profile.revision { return }

        var avatarData = existing?.avatarData
        var avatarId = existing?.avatarId
        var avatarReady = true
        if let avatar = profile.avatar {
            if avatar.id != existing?.avatarId {
                if let ciphertext = try? await api.downloadAttachment(id: avatar.id),
                   let opened = try? AttachmentCipher.open(ciphertext, key: avatar.key, digest: avatar.digest) {
                    let plaintext = SafeImage.avatarJPEG(from: opened)
                    // Under Communication Safety a flagged photo is never shown,
                    // so it isn't kept either.
                    let flagged = if let plaintext, SensitiveContent.isRestricted {
                        await SensitiveContent.isSensitive(imageData: plaintext)
                    } else { false }
                    avatarData = flagged ? nil : plaintext
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

    /// The per-install secret that picks directory-lookup decoys, kept so a
    /// contact's decoys stay the same across launches (see DirectoryBuckets).
    private func loadDirectoryDecoySeed() {
        let key = "directory:decoySeed"
        if let seed = (try? storage.database.query("SELECT value FROM kv WHERE key = ?", [.text(key)]).first?.first?.data) ?? nil,
           seed.count == 32 {
            DirectoryBuckets.decoySeed = seed
            return
        }
        var seed = Data(count: 32)
        guard seed.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess
        else { return }
        try? storage.database.run("INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)", [.text(key), .blob(seed)])
        DirectoryBuckets.decoySeed = seed
    }

    static func groupAddedByKey(_ groupId: String) -> String { "group:addedBy:" + groupId }

    /// Who added us to a group that's still a message request.
    func groupRequestAdder(groupId: String) -> String? {
        let data = (try? storage.database.query(
            "SELECT value FROM kv WHERE key = ?", [.text(Self.groupAddedByKey(groupId))]
        ).first?.first?.data) ?? nil
        return data.flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 }
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

    func cachedUsername(_ account: String) -> String? {
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

    func insertRelayMessage(_ text: String, conversationId: String) {
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

    // MARK: - View state refresh

    func peerAccount(for conversationId: String) throws -> String? {
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

    /// Loads the next page of older messages into the open chat.
    func loadEarlierMessages() {
        guard let conversationId = activeConversationId, hasEarlierMessages else { return }
        activeMessageLimit += Self.messagePageSize
        refreshActiveMessages(ifShowing: conversationId)
    }

    func refreshActiveMessages(ifShowing conversationId: String) {
        guard activeConversationId == conversationId else { return }
        let messageStore = storage.messages
        let limit = activeMessageLimit
        Task.detached(priority: .userInitiated) { [weak self] in
            // One extra row tells whether anything older exists.
            var msgs = (try? messageStore.messages(in: conversationId, limit: limit + 1)) ?? []
            let hasEarlier = msgs.count > limit
            if hasEarlier { msgs.removeFirst() }
            await MainActor.run { [weak self] in
                guard let self, self.activeConversationId == conversationId, self.activeMessageLimit == limit else { return }
                self.activeMessages = msgs
                self.hasEarlierMessages = hasEarlier
                self.activeMessagesRevision &+= 1
                self.messagesLoadedConversationId = conversationId
            }
        }
    }
}

/// Never-reused prekey ids, persisted in the encrypted kv table.
nonisolated final class KVPreKeyIdAllocator: PreKeyIdAllocating, @unchecked Sendable {
    let database: Database

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
