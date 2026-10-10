//
//  CallManager.swift
//  Relay
//
//  WebRTC call state machine. Handles offer/answer/ICE exchange over the
//  existing E2EE envelope channel and reports call events to CallKit.
//

import AudioToolbox
import AVFoundation
@preconcurrency import CallKit
import Foundation
import OSLog
import ReplayKit
import RelayCore
import RelayKit
import SecureStorage
import UIKit
import UserNotifications
import WebRTC

// MARK: - Call state

enum CallKind: String, Equatable {
    case audio, video
}

struct GroupCallPeer: Identifiable {
    var id: String { peerAccount }
    let peerAccount: String
    let peerName: String
    var peerConnection: RTCPeerConnection?
    var remoteVideoTrack: RTCVideoTrack?
    var isConnected: Bool = false
    var pendingCandidates: [RTCIceCandidate] = []
    var hasRemoteDescription: Bool = false
}

/// Host side: someone who opened one of our call links and is waiting to be let in.
struct LinkJoinRequest: Identifiable, Equatable {
    let account: String
    let name: String
    let callId: String
    var id: String { callId + "|" + account }
}

/// Joiner side: our request to join someone else's call link.
struct OutgoingLinkJoin: Equatable {
    enum Status: Equatable { case waiting, denied, noAnswer }
    let callId: String
    let hostAccount: String
    let secret: String
    let hostName: String
    var status: Status
}

struct GroupRingInfo {
    let callId: String
    let groupId: String
    let callerAccount: String
    let callerName: String
    let participants: [String]
    let kind: CallKind
}

enum CallState: Equatable {
    case idle
    case outgoing(callId: String, peerAccount: String, peerName: String)
    case incoming(callId: String, callerAccount: String, callerName: String)
    case connecting
    case active(callId: String, startedAt: Date)
    case failed(String)
    case ended
}

struct CallDiagnostics: Equatable {
    var iceConnectionState = "Idle"
    var iceGatheringState = "Idle"
    var signalingState = "Stable"
    var localVideoActive = false
    var remoteVideoActive = false
    var screenSharingActive = false
    var lastUpdated = Date()
}

// MARK: - CallManager

@Observable
@MainActor
final class CallManager: NSObject {
    private(set) var state: CallState = .idle
    private(set) var isMuted = false
    private(set) var isSpeaker = false
    private(set) var isVideoEnabled = true
    private(set) var isScreenSharing = false
    private(set) var localVideoTrack: RTCVideoTrack?
    private(set) var remoteVideoTrack: RTCVideoTrack?
    private(set) var diagnostics = CallDiagnostics()

    var currentCallKind: CallKind { storedCallKind }

    var onSendCallMessage: ((Relay_Content_CallMessage, String) async -> Bool)?
    var onSendGroupCallMessage: ((Relay_Content_CallMessage, [String]) async -> Void)?
    /// Wakes the callee's device(s) with a VoIP push. (account, callId) — the push
    /// carries ONLY the call id; caller identity travels inside the E2E OFFER.
    var onTriggerPush: ((String, String) async -> Void)?
    /// True when calls from this account must be dropped (blocked contact).
    var isBlockedAccount: ((String) -> Bool)?
    /// Returns the locally stored member list for a group id (nil = unknown group).
    /// Group-call signals are accepted only from members of that roster.
    var groupMembersResolver: ((String) -> [String]?)?
    /// Called when a VoIP push reported a (still anonymous) incoming call, so the
    /// app can reconnect and replay NSE-persisted OFFERs to learn the caller.
    var onAwaitingCallOffer: (() -> Void)?

    // MARK: Group call state
    private(set) var isInGroupCall = false
    private(set) var groupPeers: [String: GroupCallPeer] = [:]
    private(set) var groupRingInfo: GroupRingInfo? = nil
    private(set) var groupCallKind: CallKind = .audio
    private(set) var groupCallDisplayName: String = "Group Call"
    /// Set when a group call couldn't start/join (e.g. relay-only mode with no
    /// TURN server). The UI shows it once and clears it.
    var groupCallFailureMessage: String?
    var ownAccountId: String?
    private var groupCallId: String?
    private var groupCallGroupId: String?
    private var groupCallLocalAudioTrack: RTCAudioTrack?
    private var groupCallLocalVideoSource: RTCVideoSource?
    private var groupCallLocalVideoCapturer: RTCCameraVideoCapturer?
    private(set) var groupCallLocalVideoTrack: RTCVideoTrack?
    private var groupPeerDelegates: [String: GroupPCDelegate] = [:]

    // MARK: Call link state
    /// Host side: people waiting to be admitted to one of our call links.
    private(set) var linkJoinRequests: [LinkJoinRequest] = []
    /// Joiner side: our pending request to join a call link.
    private(set) var outgoingLinkJoin: OutgoingLinkJoin?
    /// Who hosts the call-link call we're in (our own id when we host it).
    private var linkHostAccount: String?
    /// Returns the secret of a call link we created, by call id.
    var callLinkSecretResolver: ((String) -> String?)?
    /// Returns the name of a call link we created, by call id.
    var callLinkNameResolver: ((String) -> String?)?
    /// Resolves an account UUID to a human display name for CallKit / CallView labels.
    var nameResolver: ((String) -> String)?
    /// Persists call records after the call reaches a terminal state.
    var onRecordCall: ((StoredCall) -> Void)?
    /// Returns fresh TURN credentials from the server; nil if TURN not configured.
    /// `afterFailure`: asked while reconnecting a call whose relay failed.
    var onFetchTurnCredentials: ((_ afterFailure: Bool) async throws -> TurnCredentials?)?
    /// While set (and in the future), TURN fetches say the call's relay failed,
    /// so the relay checks its own TURN at once instead of waiting ~15 s.
    private var reconnectingUntil: Date?

    nonisolated static let privateCallModeKey = "relay.privateCallMode"
    nonisolated static let callsInRecentsKey = "relay.callsInRecents"

    /// When true (the default), calls use TURN-relay-only ICE: the other person
    /// only ever sees Relay's TURN server, never this device's IP address. If no
    /// TURN server is available the call FAILS rather than silently falling back
    /// to direct (IP-revealing) candidates. Turning this off is an explicit opt-out.
    var privateCallMode: Bool {
        get { Self.isPrivateCallModeEnabled }
        set { UserDefaults.standard.set(newValue, forKey: Self.privateCallModeKey) }
    }

    nonisolated static var isPrivateCallModeEnabled: Bool {
        UserDefaults.standard.object(forKey: privateCallModeKey) as? Bool ?? true
    }

    /// Whether Relay calls appear in the system Phone app's Recents (and iCloud
    /// call-history sync). Default OFF — call metadata stays inside Relay.
    nonisolated static var includeCallsInRecents: Bool {
        UserDefaults.standard.bool(forKey: callsInRecentsKey)
    }

    private static let noRelayServerMessage =
        "Private calling needs Relay’s relay server, which isn’t reachable right now. Try again shortly. (You can allow direct calls in Profile → Privacy, but that reveals your IP address to the other person.)"

    private static func hasTurnServer(_ servers: [RTCIceServer]) -> Bool {
        servers.contains { $0.urlStrings.contains { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") } }
    }

    /// True when `candidateSDP` is a TURN-relayed candidate (the only kind that
    /// may leave this device while relay-only mode is on).
    nonisolated static func isRelayCandidate(_ candidateSDP: String) -> Bool {
        candidateSDP.contains(" typ relay")
    }

    /// Removes every non-relay `a=candidate` line from an SDP when relay-only
    /// mode is on, as a belt-and-braces guard against host/srflx addresses
    /// riding along inside an offer/answer.
    nonisolated static func sanitizeSDP(_ sdp: String) -> String {
        guard isPrivateCallModeEnabled else { return sdp }
        let separator = sdp.contains("\r\n") ? "\r\n" : "\n"
        return sdp.components(separatedBy: separator).filter { line in
            guard line.hasPrefix("a=candidate:") else { return true }
            return isRelayCandidate(line)
        }.joined(separator: separator)
    }

    /// Set when the last peer-connection creation failed for a user-facing reason.
    private var peerConnectionFailureReason: String?

    /// Opaque CallKit handle: a random per-call value. Never the account id or
    /// display name — CallKit handles can reach system call history.
    private static func opaqueHandle() -> CXHandle {
        CXHandle(type: .generic, value: UUID().uuidString)
    }

    /// Call-screen caller label, honoring the notification-preview privacy level.
    private func callKitCallerName(_ name: String?) -> String {
        guard NotificationPreviewSetting.current.showsSenderName, let name, !name.isEmpty else { return "Relay" }
        return name
    }

    /// Timer that ends an anonymous VoIP-reported call if its E2E OFFER never arrives.
    private var offerWaitTask: Task<Void, Never>?
    /// Group roster (minus self) for the current group call.
    private var groupCallMembers: Set<String> = []

    // Short-lived TURN credential cache (avoids a fetch on every peer-connection creation).
    private var cachedTurnCredentials: (creds: TurnCredentials, expiresAt: Date)?

    private var peerConnection: RTCPeerConnection?
    private var hasAnsweredCall = false
    private var wasIncomingCall = false   // true when we are the callee
    private var callTimeoutTask: Task<Void, Never>?
    private var iceRecoveryTask: Task<Void, Never>?
    /// Mid-call reconnection (1:1): rebuilds ICE with fresh TURN servers.
    private var iceRestartTask: Task<Void, Never>?
    /// A connected 1:1 call lost its connection and is reconnecting (the UI
    /// shows a no-signal symbol by the timer so it doesn't look frozen).
    private(set) var isReconnecting = false
    /// Mid-call reconnection (group): one task per peer.
    private var groupReconnectTasks: [String: Task<Void, Never>] = [:]
    // Candidates that arrived before setRemoteDescription was called; drained immediately after.
    private var pendingRemoteCandidates: [RTCIceCandidate] = []
    private var hasRemoteDescription = false
    // Persisted across state transitions so ICE candidates, hangup, and
    // UI labels work regardless of which CallState we're currently in.
    private var storedCallPeer: String?
    private var storedCallId: String?
    private var storedCallStartedAt: Date?
    private var storedCallConnectedAt: Date?
    private var storedCallKind: CallKind = .audio
    private(set) var storedPeerName: String?
    var storedPeerAccount: String? { storedCallPeer }
    private let factory: RTCPeerConnectionFactory
    private let provider: CXProvider
    private let callController = CXCallController()
    private var activeCallUUID: UUID?
    // True only when reportNewIncomingCall or CXStartCallAction has been filed with
    // CallKit. Foreground WS-path incoming calls skip CallKit entirely (no system UI)
    // and therefore must not send CXEndCallAction / reportCall on teardown.
    private var hasCallKitReport = false
    private var localAudioTrack: RTCAudioTrack?
    private var localVideoSource: RTCVideoSource?
    private var localVideoCapturer: RTCCameraVideoCapturer?
    private var screenVideoCapturer: RTCVideoCapturer?
    private var deviceBroadcastTask: Task<Void, Never>?
    private var deviceBroadcastFrameModifiedAt: Date?
    private var isUsingDeviceBroadcast = false
    private let screenRecorder = RPScreenRecorder.shared()
    private var pendingOffer: Relay_Content_CallMessage?
    private var ringTask: Task<Void, Never>?

    nonisolated private static let broadcastAppGroupId = "group.app.relaymsg"
    nonisolated private static let broadcastFrameFilename = "RelayBroadcastFrame.jpg"
    private let log = Logger(subsystem: "app.relaymsg", category: "CallManager")

    var needsSignalingConnection: Bool {
        if isInGroupCall { return true }
        switch state {
        case .idle, .ended, .failed:
            return false
        case .outgoing, .incoming, .connecting, .active:
            return true
        }
    }

    // The provider config is rebuilt and re-applied before every report: it is
    // the iOS 18.4.1+ workaround for unreliable didActivate, and it picks up the
    // current "Show in Recents" preference.
    private func makeProviderConfiguration() -> CXProviderConfiguration {
        Self.providerConfiguration()
    }

    private static func providerConfiguration() -> CXProviderConfiguration {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        // Keep Relay calls out of the Phone app's Recents (and iCloud call
        // history) unless the user explicitly opts in.
        config.includesCallsInRecents = includeCallsInRecents
        return config
    }

    override init() {
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)

        provider = CXProvider(configuration: Self.providerConfiguration())
        super.init()
        provider.setDelegate(self, queue: nil)
        // Must be set before any peer connection is created. When true,
        // RTCAudioSession only starts audio hardware when isAudioEnabled is
        // explicitly set — which happens in provider(_:didActivate:) via
        // CallKit. Without this flag isAudioEnabled is ignored and WebRTC
        // tries to manage the session itself, conflicting with CallKit.
        RTCAudioSession.sharedInstance().useManualAudio = true
        RTCAudioSession.sharedInstance().isAudioEnabled = false
    }

    // MARK: - Outgoing call

    /// The iPhone/iPad app running on a Mac. 1:1 calls go through CallKit,
    /// which isn't available there; group calls and call links don't use it.
    nonisolated static var isOnMac: Bool { ProcessInfo.processInfo.isiOSAppOnMac }
    nonisolated static let macOneToOneCallMessage =
        "Calls with one person aren't available in the Mac version yet. Start the call from your iPhone or iPad. Group calls and call links work here."

    func startCall(peerAccount: String, peerName: String, kind: CallKind = .audio) async {
        guard case .idle = state else { return }
        if Self.isOnMac {
            groupCallFailureMessage = Self.macOneToOneCallMessage
            return
        }
        let callId = UUID().uuidString
        let uuid = UUID()
        activeCallUUID = uuid
        hasCallKitReport = true
        storedCallPeer = peerAccount
        storedCallId = callId
        storedCallStartedAt = Date()
        storedCallConnectedAt = nil
        storedCallKind = kind
        storedPeerName = peerName
        resetDiagnostics()
        state = .outgoing(callId: callId, peerAccount: peerAccount, peerName: peerName)
        log.info("startCall: peer and call id redacted")

        // Opaque handle: CallKit (and, if enabled, Recents) never sees the
        // peer's account id. The visible name is set locally via
        // localizedCallerName below.
        let action = CXStartCallAction(call: uuid, handle: Self.opaqueHandle())
        action.isVideo = kind == .video
        do {
            try await callController.requestTransaction(with: action)
            let update = CXCallUpdate()
            update.localizedCallerName = callKitCallerName(peerName)
            update.hasVideo = kind == .video
            provider.reportCall(with: uuid, updated: update)
        } catch {
            log.error("startCall: CXStartCallAction rejected: \(PrivacyRedactor.error(error))")
        }

        // Every await below can outlive the call (CallKit or the user may end
        // it meanwhile); bail out rather than invite the peer to a dead call.
        func stillOurs() -> Bool {
            if case .outgoing(let id, _, _) = state, id == callId { return true }
            return false
        }
        guard stillOurs() else { return }
        if kind == .video {
            await requestCameraAccessIfNeeded()
        }
        configureAudioSessionForCall()
        guard stillOurs() else { return }
        guard let pc = await makePeerConnection() else {
            failPeerConnectionSetup(notifyPeer: false)
            return
        }
        peerConnection = pc
        addLocalMedia(to: pc, kind: kind)

        log.info("startCall: creating offer")
        let offer = try? await pc.offer(for: defaultConstraints(kind: kind))
        guard let offer else {
            log.error("startCall: failed to create offer — terminating")
            terminate(fromRemote: false)
            return
        }
        try? await pc.setLocalDescription(offer)
        guard stillOurs() else {
            log.info("startCall: call ended before the invite was sent")
            return
        }
        log.info("startCall: offer ready, sending + triggering push")

        var msg = Relay_Content_CallMessage()
        msg.type = .offer
        msg.callID = callId
        msg.sdp = Self.sanitizeSDP(offer.sdp)
        msg.ice = Self.metadataJSON(kind: kind)
        guard await (onSendCallMessage?(msg, peerAccount) ?? false) else {
            failCall("Couldn’t send the call invite.", notifyPeer: false)
            return
        }
        // The VoIP push carries only the call id — no caller name, account or kind.
        await onTriggerPush?(peerAccount, callId)
        log.info("startCall: invite sent; waiting for answer")

        // Auto-hang-up if callee never answers within 45 seconds.
        callTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard let self, !Task.isCancelled else { return }
            guard case .active = self.state else {
                self.failCall("No answer.", notifyPeer: true)
                return
            }
        }
    }

    // MARK: - Incoming call (from VoIP push or WS envelope)

    /// Seconds an anonymous VoIP-reported call waits for its E2E OFFER before
    /// it is ended (the push alone proves nothing about who is calling).
    private static let offerWaitSeconds: Double = 10

    /// VoIP push path. The push carries ONLY a call id, so nothing about the
    /// caller is known (or trusted) yet: report a generic "Relay" call to CallKit
    /// immediately — PushKit requires it — and wait for the end-to-end encrypted
    /// OFFER with the same call id to reveal the caller. If none arrives within
    /// `offerWaitSeconds`, the call is ended.
    func reportIncomingPushCall(callId: String, pushCompletion: @escaping () -> Void) {
        // Group calls never use VoIP pushes, and a call already registered over
        // the WebSocket (it beat the push) needs no second report.
        if isInGroupCall {
            reportAndEndRejectedPushCall(completion: pushCompletion)
            return
        }
        if case .incoming(let existingId, _, _) = state, existingId == callId {
            pushCompletion()
            return
        }
        guard case .idle = state, !callId.isEmpty else {
            // Busy (or malformed push). We can't send BUSY — the caller is unknown
            // until the OFFER arrives, and that OFFER is answered with BUSY by
            // `reportIncomingCall` when it does.
            reportAndEndRejectedPushCall(completion: pushCompletion)
            return
        }
        let uuid = UUID()
        activeCallUUID = uuid
        storedCallPeer = nil
        storedCallId = callId
        storedCallStartedAt = Date()
        storedCallConnectedAt = nil
        storedCallKind = .audio
        storedPeerName = nil
        wasIncomingCall = true
        resetDiagnostics()
        state = .incoming(callId: callId, callerAccount: "", callerName: "Relay")
        hasCallKitReport = true

        let update = CXCallUpdate()
        update.remoteHandle = Self.opaqueHandle()
        update.localizedCallerName = "Relay"
        update.hasVideo = false
        provider.configuration = makeProviderConfiguration()
        provider.reportNewIncomingCall(with: uuid, update: update) { [log] error in
            if let error {
                log.error("report incoming push call failed: \(PrivacyRedactor.error(error))")
            }
            pushCompletion()
        }

        offerWaitTask?.cancel()
        offerWaitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.offerWaitSeconds))
            guard let self, !Task.isCancelled else { return }
            guard self.storedCallId == callId, self.storedCallPeer?.isEmpty != false else { return }
            self.log.warning("no OFFER arrived for VoIP-reported call; ending it")
            self.endUnverifiedCall()
        }
        onAwaitingCallOffer?()
    }

    /// True while an anonymous VoIP-reported call is still waiting for its OFFER.
    private var isAwaitingCallerIdentity: Bool {
        wasIncomingCall && storedCallId != nil && storedCallPeer?.isEmpty != false
    }

    /// Ends an anonymous call whose caller never proved who they are (no OFFER,
    /// or the OFFER came from a blocked account). Nothing is sent, recorded, or
    /// shown as a missed call.
    private func endUnverifiedCall() {
        offerWaitTask?.cancel()
        offerWaitTask = nil
        stopRingtone()
        callTimeoutTask?.cancel()
        callTimeoutTask = nil
        stopVideoCapture()
        peerConnection?.close()
        peerConnection = nil
        if hasCallKitReport, let uuid = activeCallUUID {
            provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
        }
        activeCallUUID = nil
        hasCallKitReport = false
        pendingOffer = nil
        pendingRemoteCandidates.removeAll()
        hasRemoteDescription = false
        storedCallPeer = nil
        storedCallId = nil
        storedCallStartedAt = nil
        storedCallConnectedAt = nil
        storedCallKind = .audio
        storedPeerName = nil
        hasAnsweredCall = false
        wasIncomingCall = false
        isMuted = false
        isSpeaker = false
        isVideoEnabled = true
        isScreenSharing = false
        resetDiagnostics()
        state = .idle
    }

    /// Binds the verified sender of an OFFER to an anonymous VoIP-reported call
    /// and updates CallKit with the locally resolved name. Returns false (and
    /// ends the call) if the caller is blocked.
    private func bindCallerToPushCall(_ account: String, kind: CallKind) -> Bool {
        offerWaitTask?.cancel()
        offerWaitTask = nil
        if isBlockedAccount?(account) == true {
            log.info("dropping call from a blocked account")
            endUnverifiedCall()
            return false
        }
        let name = nameResolver?(account) ?? "Unknown"
        storedCallPeer = account
        storedPeerName = name
        storedCallKind = kind
        if case .incoming(let callId, _, _) = state {
            state = .incoming(callId: callId, callerAccount: account, callerName: name)
        }
        if hasCallKitReport, let uuid = activeCallUUID {
            let update = CXCallUpdate()
            update.localizedCallerName = callKitCallerName(name)
            update.hasVideo = kind == .video
            provider.reportCall(with: uuid, updated: update)
        }
        return true
    }

    /// WebSocket / replayed-OFFER path: the caller is already authenticated by
    /// the E2E envelope.
    func reportIncomingCall(
        callId: String,
        callerAccount: String,
        callerName: String,
        kind: CallKind = .audio
    ) {
        if isBlockedAccount?(callerAccount) == true {
            log.info("ignoring call from a blocked account")
            return
        }
        if isInGroupCall { return }
        if case .incoming(let existingId, _, _) = state, existingId == callId { return }
        guard case .idle = state else {
            Task {
                var msg = Relay_Content_CallMessage()
                msg.type = .busy
                msg.callID = callId
                _ = await onSendCallMessage?(msg, callerAccount)
            }
            return
        }
        let uuid = UUID()
        activeCallUUID = uuid
        storedCallPeer = callerAccount
        storedCallId = callId
        storedCallStartedAt = Date()
        storedCallConnectedAt = nil
        storedCallKind = kind
        storedPeerName = callerName
        wasIncomingCall = true
        resetDiagnostics()
        state = .incoming(callId: callId, callerAccount: callerAccount, callerName: callerName)

        // When the app is foregrounded and the call arrived via WebSocket (no VoIP
        // push), skip the CallKit system UI. Our in-app CallView handles the incoming
        // call banner; showing the CallKit sheet on top creates a double UI. Audio is
        // activated manually in answerCall() instead of via provider(_:didActivate:).
        if UIApplication.shared.applicationState == .active {
            startRingtone()
            return
        }

        hasCallKitReport = true
        let update = CXCallUpdate()
        update.remoteHandle = Self.opaqueHandle()
        update.localizedCallerName = callKitCallerName(callerName)
        update.hasVideo = kind == .video
        // iOS 18.4.1+ bug: provider(_:didActivate:) is unreliable. Apple's
        // official workaround: call setConfiguration before reportNewIncomingCall
        // to force the audio session to activate correctly.
        provider.configuration = makeProviderConfiguration()
        provider.reportNewIncomingCall(with: uuid, update: update) { [log] error in
            if let error {
                log.error("report incoming call failed: \(PrivacyRedactor.error(error))")
            }
        }
    }

    /// Satisfies PushKit for a push we won't ring for: report a generic call
    /// and end it immediately.
    private func reportAndEndRejectedPushCall(completion: @escaping () -> Void) {
        let uuid = UUID()
        let update = CXCallUpdate()
        update.remoteHandle = Self.opaqueHandle()
        update.localizedCallerName = "Relay"
        update.hasVideo = false
        provider.configuration = makeProviderConfiguration()
        provider.reportNewIncomingCall(with: uuid, update: update) { [provider, log] error in
            if let error {
                log.error("report rejected incoming call failed: \(PrivacyRedactor.error(error))")
            }
            provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
            completion()
        }
    }

    // MARK: - Answer (in-app button)

    func answerCall() async {
        guard case .incoming(_, let callerAccount, _) = state, !hasAnsweredCall else { return }
        let answerPeer = (storedCallPeer?.isEmpty == false ? storedCallPeer : nil) ?? callerAccount
        hasAnsweredCall = true
        stopRingtone()
        if storedCallKind == .video {
            await requestCameraAccessIfNeeded()
        }
        configureAudioSessionForCall()
        guard let pc = await makePeerConnection() else {
            failPeerConnectionSetup(notifyPeer: true)
            return
        }
        peerConnection = pc
        addLocalMedia(to: pc, kind: storedCallKind)
        state = .connecting
        if let offer = pendingOffer {
            pendingOffer = nil
            await applyOffer(offer, from: answerPeer)
        }
        if hasCallKitReport, let uuid = activeCallUUID {
            // Tell CallKit the call is answered so system controls work.
            let action = CXAnswerCallAction(call: uuid)
            try? await callController.requestTransaction(with: action)
        } else {
            // Foreground-path incoming call: CallKit never reported the call so
            // provider(_:didActivate:) won't fire. Activate audio manually.
            let avSession = AVAudioSession.sharedInstance()
            try? avSession.setActive(true)
            RTCAudioSession.sharedInstance().audioSessionDidActivate(avSession)
            RTCAudioSession.sharedInstance().isAudioEnabled = true
        }
    }

    // Called by CXProviderDelegate for lock-screen answers.
    func callKitAnswered() async {
        guard case .incoming(_, let callerAccount, _) = state, !hasAnsweredCall else { return }
        let answerPeer = (storedCallPeer?.isEmpty == false ? storedCallPeer : nil) ?? callerAccount
        hasAnsweredCall = true
        if storedCallKind == .video {
            await requestCameraAccessIfNeeded()
        }
        configureAudioSessionForCall()
        guard let pc = await makePeerConnection() else {
            failPeerConnectionSetup(notifyPeer: true)
            return
        }
        peerConnection = pc
        addLocalMedia(to: pc, kind: storedCallKind)
        state = .connecting
        if let offer = pendingOffer {
            pendingOffer = nil
            await applyOffer(offer, from: answerPeer)
        }
    }

    /// Fails the call after `makePeerConnection` returned nil, surfacing the
    /// relay-only reason when that's what blocked it.
    private func failPeerConnectionSetup(notifyPeer: Bool) {
        let reason = peerConnectionFailureReason ?? "Couldn’t set up this call."
        peerConnectionFailureReason = nil
        failCall(reason, notifyPeer: notifyPeer)
    }

    // MARK: - Incoming call message routing

    func handleIncomingCall(_ info: CallInfo) async {
        var msg = Relay_Content_CallMessage()
        msg.callID = info.callId
        msg.sdp = info.sdp
        msg.ice = info.ice
        msg.groupID = info.groupId
        msg.targetAccount = info.targetAccount
        msg.participants = info.participants
        switch info.type {
        case .offer:      msg.type = .offer
        case .answer:     msg.type = .answer
        case .ice:        msg.type = .ice
        case .hangup:     msg.type = .hangup
        case .busy:       msg.type = .busy
        case .ringing:    msg.type = .ringing
        case .groupRing:  msg.type = .groupRing
        case .groupJoin:  msg.type = .groupJoin
        case .groupLeave: msg.type = .groupLeave
        case .linkJoinRequest: msg.type = .linkJoinRequest
        case .linkAdmit:  msg.type = .linkAdmit
        case .linkRoster: msg.type = .linkRoster
        case .linkDeny:   msg.type = .linkDeny
        }
        await handleCallMessage(msg, from: info.callerAccount)
    }

    /// A 1:1 control signal (ANSWER / ICE / HANGUP / BUSY) is honored only when
    /// it comes from the stored call peer AND names the stored call id. Anything
    /// else — another contact, a stale call, a guessed id — is ignored.
    private func isFromCurrentCallPeer(_ msg: Relay_Content_CallMessage, account: String) -> Bool {
        guard !account.isEmpty,
              let peer = storedCallPeer, !peer.isEmpty, peer == account,
              let callId = storedCallId, !callId.isEmpty, callId == msg.callID
        else { return false }
        return true
    }

    func handleCallMessage(_ msg: Relay_Content_CallMessage, from account: String) async {
        // Route all group-call signals to the dedicated handler.
        if !msg.groupID.isEmpty || msg.type == .groupRing || msg.type == .groupJoin || msg.type == .groupLeave {
            await handleGroupCallMessage(msg, from: account)
            return
        }
        guard !account.isEmpty else { return }
        switch msg.type {
        case .offer:
            // On a Mac there is no CallKit; leave the ringing to the iPhone/iPad.
            if Self.isOnMac { return }
            let kind = Self.callKind(fromMetadata: msg.ice) ?? (Self.sdpContainsVideo(msg.sdp) ? .video : .audio)
            let inCall: Bool
            switch state {
            case .connecting, .active: inCall = true
            default: inCall = false
            }
            if inCall, peerConnection != nil, storedCallId == msg.callID {
                // We already have a peer connection for this call. This OFFER is
                // either the initial one arriving after callKitAnswered() (callee),
                // or a mid-call ICE-restart OFFER (fresh SDP, same callId). Both
                // renegotiate in place: apply the remote offer, drain candidates,
                // and answer on the same callId. No CallKit state change, no BUSY —
                // this is not a new call. Cancel any armed ICE-failure grace timer,
                // since this OFFER is the recovery attempt.
                if isAwaitingCallerIdentity {
                    // Answered from CallKit before the OFFER revealed the caller.
                    guard bindCallerToPushCall(account, kind: kind) else { return }
                } else {
                    guard storedCallPeer == account else {
                        log.warning("ignoring OFFER from a non-participant")
                        return
                    }
                }
                iceRecoveryTask?.cancel()
                iceRecoveryTask = nil
                storedCallKind = kind
                updateCallKitVideoIfNeeded(kind: kind)
                if storedCallConnectedAt != nil, let pc = peerConnection {
                    // A reconnection offer: pick up the current TURN servers
                    // first, in case ours went down.
                    markReconnecting()
                    await refreshIceServers(on: pc)
                }
                await applyOffer(msg, from: account)
            } else if case .incoming(let existingId, _, _) = state, existingId == msg.callID {
                // VoIP push (or an earlier copy of this OFFER) already registered
                // this call; store SDP for when the user answers.
                if isAwaitingCallerIdentity {
                    guard bindCallerToPushCall(account, kind: kind) else { return }
                } else {
                    guard storedCallPeer == account else {
                        log.warning("ignoring OFFER from a non-participant")
                        return
                    }
                    storedCallKind = kind
                    updateCallKitVideoIfNeeded(kind: kind)
                }
                pendingOffer = msg
            } else {
                // Fresh incoming call via WS — resolve display name locally before reporting.
                if isBlockedAccount?(account) == true { return }
                let displayName = nameResolver?(account) ?? "Unknown"
                reportIncomingCall(callId: msg.callID, callerAccount: account, callerName: displayName, kind: kind)
                if case .incoming(let id, let caller, _) = state, id == msg.callID, caller == account {
                    pendingOffer = msg
                }
            }

        case .answer:
            guard isFromCurrentCallPeer(msg, account: account), !wasIncomingCall else {
                log.warning("ignoring ANSWER that doesn't match the current call")
                return
            }
            guard let pc = peerConnection else { return }
            let desc = RTCSessionDescription(type: .answer, sdp: msg.sdp)
            do {
                try await pc.setRemoteDescription(desc)
                hasRemoteDescription = true
                await drainPendingCandidates(into: pc)
                updateRemoteVideoTrack(from: pc)
                log.info("received call ANSWER; waiting for ICE connection")
                if case .outgoing = state {
                    state = .connecting
                }
            } catch {
                log.error("failed to apply call ANSWER: \(PrivacyRedactor.error(error))")
                failCall("Couldn’t connect this call.", notifyPeer: true)
            }

        case .ice:
            guard isFromCurrentCallPeer(msg, account: account) else { return }
            guard let candidate = parseIce(msg.ice) else { return }
            if let pc = peerConnection, hasRemoteDescription {
                try? await pc.add(candidate)
            } else {
                // Remote description not yet applied — queue for drain after setRemoteDescription.
                pendingRemoteCandidates.append(candidate)
                log.info("ICE candidate queued (no remote description yet); queue=\(self.pendingRemoteCandidates.count)")
            }

        case .hangup:
            guard isFromCurrentCallPeer(msg, account: account) else {
                log.warning("ignoring HANGUP that doesn't match the current call")
                return
            }
            terminate(fromRemote: true)

        case .busy:
            guard isFromCurrentCallPeer(msg, account: account), !wasIncomingCall else {
                log.warning("ignoring BUSY that doesn't match the current call")
                return
            }
            terminate(fromRemote: true, outcomeOverride: .declined)

        case .ringing, .groupRing, .groupJoin, .groupLeave,
             .linkJoinRequest, .linkAdmit, .linkRoster, .linkDeny, .UNRECOGNIZED:
            break
        }
    }

    private func updateCallKitVideoIfNeeded(kind: CallKind) {
        guard kind == .video, hasCallKitReport, let uuid = activeCallUUID else { return }
        let update = CXCallUpdate()
        update.localizedCallerName = callKitCallerName(storedPeerName)
        update.hasVideo = true
        provider.reportCall(with: uuid, updated: update)
    }

    private static func metadataJSON(kind: CallKind) -> String {
        guard kind == .video else { return "" }
        return "{\"kind\":\"video\"}"
    }

    private static func callKind(fromMetadata metadata: String) -> CallKind? {
        guard let data = metadata.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = dict["kind"] as? String
        else { return nil }
        return kind == "video" ? .video : .audio
    }

    private static func sdpContainsVideo(_ sdp: String) -> Bool {
        sdp.split(separator: "\n").contains { line in
            line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("m=video")
        }
    }

    private func updateRemoteVideoTrack(from pc: RTCPeerConnection) {
        guard remoteVideoTrack == nil else { return }
        for receiver in pc.receivers {
            if let track = receiver.track as? RTCVideoTrack {
                remoteVideoTrack = track
                storedCallKind = .video
                return
            }
        }
    }

    private func requestCameraAccessIfNeeded() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            _ = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            log.warning("camera access is not available for video call")
        }
    }

    /// Points an existing connection at the TURN servers the relay hands out
    /// now (our own, or the backup when ours is down or overloaded).
    private func refreshIceServers(on pc: RTCPeerConnection) async {
        guard let config = await makeRTCConfiguration() else { return }
        if !pc.setConfiguration(config) {
            log.warning("couldn't update ICE servers on the live call")
        }
    }

    /// 1:1 mid-call reconnection. The caller drives it (the callee answers the
    /// restart OFFER, refreshing its own servers first), retrying for ~25 s:
    /// the relay needs ~10 s to notice our TURN server is gone.
    private func markReconnecting() { reconnectingUntil = Date().addingTimeInterval(60) }

    private func startIceRestart() {
        guard iceRestartTask == nil, !wasIncomingCall else { return }
        markReconnecting()
        iceRestartTask = Task { @MainActor [weak self] in
            defer { self?.iceRestartTask = nil }
            for attempt in 0..<4 {
                // First try right away: the relay now checks its TURN on the
                // spot, so a dead server is swapped for the backup immediately.
                try? await Task.sleep(for: .seconds(attempt == 0 ? 1 : 6))
                guard let self, !Task.isCancelled,
                      let pc = self.peerConnection,
                      let callId = self.storedCallId, let peer = self.storedCallPeer
                else { return }
                if pc.iceConnectionState == .connected || pc.iceConnectionState == .completed { return }
                log.info("reconnecting call (attempt \(attempt + 1))")
                await self.refreshIceServers(on: pc)
                pc.restartIce()
                guard let offer = try? await pc.offer(for: self.defaultConstraints(kind: self.storedCallKind)) else { continue }
                do { try await pc.setLocalDescription(offer) } catch { continue }
                var msg = Relay_Content_CallMessage()
                msg.type = .offer
                msg.callID = callId
                msg.sdp = Self.sanitizeSDP(offer.sdp)
                msg.ice = Self.metadataJSON(kind: self.storedCallKind)
                _ = await self.onSendCallMessage?(msg, peer)
            }
        }
    }

    /// Group mid-call reconnection: for each pair, the side with the smaller
    /// account id rebuilds the connection with a fresh offer (the other side
    /// replaces its connection when that offer arrives), retrying for ~25 s.
    private func scheduleGroupReconnect(_ account: String) {
        markReconnecting()
        guard groupReconnectTasks[account] == nil, let me = ownAccountId, me < account else { return }
        groupReconnectTasks[account] = Task { @MainActor [weak self] in
            defer { self?.groupReconnectTasks[account] = nil }
            for attempt in 0..<4 {
                try? await Task.sleep(for: .seconds(attempt == 0 ? 2 : 6))
                guard let self, !Task.isCancelled, self.isInGroupCall,
                      let callId = self.groupCallId, let peer = self.groupPeers[account]
                else { return }
                if peer.isConnected { return }
                log.info("reconnecting group peer (attempt \(attempt + 1))")
                self.closeGroupPeerConnection(forAccount: account)
                self.groupPeers[account]?.hasRemoteDescription = false
                self.groupPeers[account]?.pendingCandidates = []
                await self.initiateGroupPeerOffer(toPeer: account, callId: callId)
            }
        }
    }

    private func scheduleIceFailure(reason: String, delay: Duration) {
        guard iceRecoveryTask == nil else { return }
        log.warning("ICE reported trouble; waiting before ending call: \(PrivacyRedactor.redactedString(reason))")
        iceRecoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.failCall(reason, notifyPeer: true)
        }
    }

    private func applyOffer(_ msg: Relay_Content_CallMessage, from account: String) async {
        guard let pc = peerConnection else { return }
        let desc = RTCSessionDescription(type: .offer, sdp: msg.sdp)
        do {
            try await pc.setRemoteDescription(desc)
            hasRemoteDescription = true
            await drainPendingCandidates(into: pc)
            updateRemoteVideoTrack(from: pc)
            let answer = try await pc.answer(for: defaultConstraints(kind: storedCallKind))
            try await pc.setLocalDescription(answer)

            var reply = Relay_Content_CallMessage()
            reply.type = .answer
            reply.callID = msg.callID
            reply.sdp = Self.sanitizeSDP(answer.sdp)
            log.info("sending call ANSWER")
            guard await (onSendCallMessage?(reply, account) ?? false) else {
                failCall("Couldn’t send the call answer.", notifyPeer: false)
                return
            }
        } catch {
            log.error("failed to apply call OFFER: \(PrivacyRedactor.error(error))")
            failCall("Couldn’t answer this call.", notifyPeer: true)
        }
    }

    private func drainPendingCandidates(into pc: RTCPeerConnection) async {
        guard !pendingRemoteCandidates.isEmpty else { return }
        let queued = pendingRemoteCandidates
        pendingRemoteCandidates.removeAll()
        log.info("draining \(queued.count) queued ICE candidate(s)")
        for candidate in queued {
            try? await pc.add(candidate)
        }
    }

    private func recordStoredCall(outcome: StoredCallOutcome, endedAt: Date = Date()) {
        guard let callId = storedCallId,
              let peer = storedCallPeer,
              let name = storedPeerName,
              let startedAt = storedCallStartedAt
        else { return }
        onRecordCall?(StoredCall(
            id: callId,
            peerAccount: peer,
            peerName: name,
            direction: wasIncomingCall ? .incoming : .outgoing,
            kind: storedCallKind == .video ? .video : .audio,
            startedAt: Self.millis(startedAt),
            connectedAt: storedCallConnectedAt.map(Self.millis),
            endedAt: Self.millis(endedAt),
            outcome: outcome
        ))
    }

    private func inferredTerminalOutcome(fromRemote: Bool, override: StoredCallOutcome?) -> StoredCallOutcome {
        if let override { return override }
        if fromRemote && wasIncomingCall && !hasAnsweredCall { return .missed }
        if !fromRemote && wasIncomingCall && !hasAnsweredCall { return .declined }
        if storedCallConnectedAt != nil { return .answered }
        return .failed
    }

    private static func millis(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    // MARK: - End call

    func endActiveCall() {
        terminate(fromRemote: false)
    }

    private func failCall(_ reason: String, notifyPeer: Bool) {
        stopRingtone()
        offerWaitTask?.cancel()
        offerWaitTask = nil
        log.error("call failed: \(PrivacyRedactor.redactedString(reason))")
        callTimeoutTask?.cancel()
        callTimeoutTask = nil
        iceRecoveryTask?.cancel()
        iceRecoveryTask = nil
        iceRestartTask?.cancel()
        iceRestartTask = nil
        reconnectingUntil = nil
        isReconnecting = false
        if notifyPeer, let peer = storedCallPeer, let callId = storedCallId, !callId.isEmpty {
            Task {
                var msg = Relay_Content_CallMessage()
                msg.type = .hangup
                msg.callID = callId
                _ = await onSendCallMessage?(msg, peer)
            }
        }
        recordStoredCall(outcome: .failed)
        stopVideoCapture()
        peerConnection?.close()
        peerConnection = nil
        if hasCallKitReport, let uuid = activeCallUUID {
            provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
        }
        activeCallUUID = nil
        hasCallKitReport = false
        pendingOffer = nil
        pendingRemoteCandidates.removeAll()
        hasRemoteDescription = false
        hasAnsweredCall = false
        wasIncomingCall = false
        isMuted = false
        isSpeaker = false
        isVideoEnabled = true
        isScreenSharing = false
        resetDiagnostics()
        state = .failed(reason)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, case .failed = self.state else { return }
            self.storedCallPeer = nil
            self.storedCallId = nil
            self.storedCallStartedAt = nil
            self.storedCallConnectedAt = nil
            self.storedCallKind = .audio
            self.storedPeerName = nil
            self.state = .idle
        }
    }

    private func terminate(
        fromRemote: Bool,
        reportToCallKit: Bool = true,
        outcomeOverride: StoredCallOutcome? = nil
    ) {
        stopRingtone()
        offerWaitTask?.cancel()
        offerWaitTask = nil
        callTimeoutTask?.cancel()
        callTimeoutTask = nil
        iceRecoveryTask?.cancel()
        iceRecoveryTask = nil
        iceRestartTask?.cancel()
        iceRestartTask = nil
        reconnectingUntil = nil
        isReconnecting = false

        // Post a missed call notification when the caller hung up before we answered.
        if fromRemote && wasIncomingCall && !hasAnsweredCall, let name = storedPeerName {
            postMissedCallNotification(callerName: name)
        }

        if !fromRemote, let peer = storedCallPeer, let callId = storedCallId, !callId.isEmpty {
            Task {
                var msg = Relay_Content_CallMessage()
                msg.type = .hangup
                msg.callID = callId
                _ = await onSendCallMessage?(msg, peer)
            }
        }

        recordStoredCall(outcome: inferredTerminalOutcome(fromRemote: fromRemote, override: outcomeOverride))

        if reportToCallKit, hasCallKitReport, let uuid = activeCallUUID {
            let action = CXEndCallAction(call: uuid)
            Task { try? await callController.requestTransaction(with: action) }
        }

        stopVideoCapture()
        peerConnection?.close()
        peerConnection = nil
        activeCallUUID = nil
        hasCallKitReport = false
        pendingOffer = nil
        pendingRemoteCandidates.removeAll()
        hasRemoteDescription = false
        storedCallPeer = nil
        storedCallId = nil
        storedCallStartedAt = nil
        storedCallConnectedAt = nil
        storedCallKind = .audio
        storedPeerName = nil
        hasAnsweredCall = false
        wasIncomingCall = false
        state = .idle
        isMuted = false
        isSpeaker = false
        isVideoEnabled = true
        isScreenSharing = false
        resetDiagnostics()
    }

    private func resetDiagnostics() {
        diagnostics = CallDiagnostics()
    }

    private func updateDiagnostics(_ mutate: (inout CallDiagnostics) -> Void) {
        mutate(&diagnostics)
        diagnostics.localVideoActive = localVideoTrack?.isEnabled == true
        diagnostics.remoteVideoActive = remoteVideoTrack != nil
        diagnostics.screenSharingActive = isScreenSharing
        diagnostics.lastUpdated = Date()
    }

    // MARK: - Ringtone (foreground WS-path incoming calls)

    private func startRingtone() {
        ringTask?.cancel()
        ringTask = Task {
            while !Task.isCancelled {
                AudioServicesPlayAlertSound(SystemSoundID(1315))
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func stopRingtone() {
        ringTask?.cancel()
        ringTask = nil
    }

    private func postMissedCallNotification(callerName: String) {
        let content = UNMutableNotificationContent()
        content.title = NotificationPreviewSetting.current.showsSenderName ? callerName : "Relay"
        content.body = "Missed call"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Controls

    func toggleMute() {
        isMuted.toggle()
        localAudioTrack?.isEnabled = !isMuted
        groupCallLocalAudioTrack?.isEnabled = !isMuted
        if hasCallKitReport, let uuid = activeCallUUID {
            let action = CXSetMutedCallAction(call: uuid, muted: isMuted)
            Task { try? await callController.requestTransaction(with: action) }
        }
    }

    func toggleSpeaker() {
        isSpeaker.toggle()
        configureAudioSessionForCall(enableSpeaker: isSpeaker)
    }

    func toggleVideo() {
        if isInGroupCall {
            guard let track = groupCallLocalVideoTrack else { return }
            isVideoEnabled.toggle()
            track.isEnabled = isVideoEnabled
            return
        }
        guard let localVideoTrack else { return }
        if isScreenSharing {
            stopScreenShare(restartCamera: false)
            isVideoEnabled = false
            localVideoTrack.isEnabled = false
            updateDiagnostics { _ in }
            return
        }
        isVideoEnabled.toggle()
        localVideoTrack.isEnabled = isVideoEnabled
        updateDiagnostics { _ in }
    }

    func toggleScreenShare() {
        guard storedCallKind == .video, localVideoTrack != nil else { return }
        if isScreenSharing {
            stopScreenShare(restartCamera: true)
        } else {
            startScreenShare()
        }
    }

    func useDeviceBroadcastScreenShare() {
        guard storedCallKind == .video, localVideoTrack != nil else { return }
        if isScreenSharing {
            stopScreenShare(restartCamera: false)
        }
        startDeviceBroadcastScreenShare()
    }

    func stopSharingScreen() {
        stopScreenShare(restartCamera: true)
    }

    /// The call id when the group call in progress is a call-link call.
    var currentLinkCallId: String? {
        guard let group = groupCallGroupId, group.hasPrefix("link:") else { return nil }
        return groupCallId
    }

    /// We host the call-link call in progress (so we can invite more people).
    var isLinkHost: Bool { currentLinkCallId != nil && linkHostAccount == ownAccountId }

    func flipGroupCamera() {
        guard let capturer = groupCallLocalVideoCapturer,
              let currentInput = capturer.captureSession.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first
        else { return }
        let nextPosition: AVCaptureDevice.Position = currentInput.device.position == .front ? .back : .front
        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == nextPosition }),
              let format = Self.preferredVideoFormat(for: device)
        else { return }
        capturer.startCapture(with: device, format: format, fps: Self.preferredFPS(for: format))
    }

    func flipCamera() {
        guard !isScreenSharing,
              let capturer = localVideoCapturer,
              let currentInput = capturer.captureSession.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first
        else { return }
        let nextPosition: AVCaptureDevice.Position = currentInput.device.position == .front ? .back : .front
        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == nextPosition }) else { return }
        guard let format = Self.preferredVideoFormat(for: device) else { return }
        let fps = Self.preferredFPS(for: format)
        capturer.startCapture(with: device, format: format, fps: fps)
    }

    private func configureAudioSessionForCall(enableSpeaker: Bool? = nil) {
        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.lockForConfiguration()
        defer { rtcSession.unlockForConfiguration() }

        do {
            try rtcSession.setCategory(
                .playAndRecord,
                with: [.allowBluetoothHFP, .duckOthers]
            )
            try rtcSession.setMode(.voiceChat)
            if let enableSpeaker {
                try AVAudioSession.sharedInstance().overrideOutputAudioPort(enableSpeaker ? .speaker : .none)
            }
        } catch {
            log.error("audio session configuration failed: \(PrivacyRedactor.error(error))")
        }
    }

    // MARK: - WebRTC helpers

    /// Builds the ICE configuration for a new peer connection. In relay-only
    /// mode (the default) this returns nil — and sets
    /// `peerConnectionFailureReason` — when no TURN server is available, so the
    /// call fails instead of falling back to IP-revealing direct candidates.
    private func makeRTCConfiguration() async -> RTCConfiguration? {
        let config = RTCConfiguration()
        let servers = await freshIceServers()
        if privateCallMode {
            guard Self.hasTurnServer(servers) else {
                log.error("relay-only call mode is on but no TURN server is available; refusing to call")
                peerConnectionFailureReason = Self.noRelayServerMessage
                return nil
            }
            config.iceTransportPolicy = .relay
        }
        config.iceServers = servers
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.iceCandidatePoolSize = 4
        return config
    }

    private func makePeerConnection() async -> RTCPeerConnection? {
        peerConnectionFailureReason = nil
        guard let config = await makeRTCConfiguration() else { return nil }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            log.error("makePeerConnection: RTCPeerConnectionFactory returned nil")
            return nil
        }
        return pc
    }

    /// Returns fresh ICE servers: dynamic TURN credentials from the server (cached up to TTL),
    /// falling back to any bundle-configured relay ICE servers. No third-party STUN is
    /// ever used — if none of Relay's own servers are available, calls rely on host/relay
    /// candidates only, so a caller's IP is never disclosed to an outside provider.
    private func freshIceServers() async -> [RTCIceServer] {
        // Always ask first: the relay switches to a backup TURN provider when
        // its own server is down or overloaded, and a cached answer would keep
        // sending calls to the struggling server. The cache is only a fallback
        // for when the relay can't be reached.
        if let fetch = onFetchTurnCredentials {
            do {
                let afterFailure = reconnectingUntil.map { $0 > Date() } ?? false
                if let creds = try await fetch(afterFailure) {
                    let ttl = TimeInterval(max(creds.ttl, 60))
                    cachedTurnCredentials = (creds, Date().addingTimeInterval(ttl))
                    return iceServers(from: creds)
                }
            } catch {
                log.warning("TURN credential fetch failed: \(PrivacyRedactor.error(error))")
            }
        }
        if let cached = cachedTurnCredentials, cached.expiresAt > Date().addingTimeInterval(60) {
            return iceServers(from: cached.creds)
        }
        return Self.staticIceServers()
    }

    private func iceServers(from creds: TurnCredentials) -> [RTCIceServer] {
        // Newer relays send an ordered list (preferred first); WebRTC prefers
        // relay candidates from earlier servers.
        if let list = creds.iceServers, !list.isEmpty {
            let servers = list.compactMap { server -> RTCIceServer? in
                let turnURLs = server.urls.filter { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") }
                guard !turnURLs.isEmpty else { return nil }
                return RTCIceServer(urlStrings: turnURLs, username: server.username, credential: server.credential)
            }
            if !servers.isEmpty { return servers }
        }
        let turnURLs = creds.urls.filter { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") }
        let stunURLs = creds.urls.filter { $0.hasPrefix("stun:") }
        var servers: [RTCIceServer] = []
        if !turnURLs.isEmpty {
            servers.append(RTCIceServer(urlStrings: turnURLs, username: creds.username, credential: creds.credential))
        }
        // Relay-operated STUN is useful only for direct (opt-out) calls; in
        // relay-only mode it is never contacted.
        if !stunURLs.isEmpty, !privateCallMode {
            servers.append(RTCIceServer(urlStrings: stunURLs))
        }
        return servers.isEmpty ? Self.staticIceServers() : servers
    }

    private static func staticIceServers() -> [RTCIceServer] {
        guard let urls = Bundle.main.object(forInfoDictionaryKey: "RelayICEServerURLs") as? [String],
              !urls.isEmpty
        else { return [] }
        let username = Bundle.main.object(forInfoDictionaryKey: "RelayTURNUsername") as? String
        let credential = Bundle.main.object(forInfoDictionaryKey: "RelayTURNCredential") as? String
        let turnURLs = urls.filter { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") }
        let stunURLs = urls.filter { $0.hasPrefix("stun:") }
        var servers: [RTCIceServer] = []
        if !turnURLs.isEmpty, let u = username, let c = credential, !u.isEmpty, !c.isEmpty {
            servers.append(RTCIceServer(urlStrings: turnURLs, username: u, credential: c))
        }
        if !stunURLs.isEmpty {
            servers.append(RTCIceServer(urlStrings: stunURLs))
        }
        return servers
    }

    private func addLocalMedia(to pc: RTCPeerConnection, kind: CallKind) {
        addAudioTrack(to: pc)
        guard kind == .video else { return }
        addVideoTrack(to: pc)
    }

    private func addAudioTrack(to pc: RTCPeerConnection) {
        let audioSource = factory.audioSource(with: defaultConstraints(kind: .audio))
        let track = factory.audioTrack(with: audioSource, trackId: "audio0")
        localAudioTrack = track
        pc.add(track, streamIds: ["stream0"])
    }

    private func addVideoTrack(to pc: RTCPeerConnection) {
        let source = factory.videoSource()
        let capturer = RTCCameraVideoCapturer(delegate: source)
        source.adaptOutputFormat(toWidth: 1280, height: 720, fps: 30)
        let track = factory.videoTrack(with: source, trackId: "video0")
        localVideoSource = source
        localVideoCapturer = capturer
        localVideoTrack = track
        isVideoEnabled = true
        updateDiagnostics { _ in }
        if let sender = pc.add(track, streamIds: ["stream0"]) {
            configureVideoSender(sender)
        }
        startVideoCapture(capturer)
    }

    private func configureVideoSender(_ sender: RTCRtpSender) {
        let parameters = sender.parameters
        guard let encoding = parameters.encodings.first else { return }
        encoding.minBitrateBps = NSNumber(value: 900_000)
        encoding.maxBitrateBps = NSNumber(value: 2_500_000)
        encoding.maxFramerate = NSNumber(value: 30)
        encoding.scaleResolutionDownBy = NSNumber(value: 1.0)
        sender.parameters = parameters
    }

    private func startVideoCapture(_ capturer: RTCCameraVideoCapturer) {
        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == .front })
                ?? RTCCameraVideoCapturer.captureDevices().first,
              let format = Self.preferredVideoFormat(for: device)
        else { return }
        capturer.startCapture(with: device, format: format, fps: Self.preferredFPS(for: format))
    }

    private static func preferredVideoFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let targetPixels: Int32 = 1280 * 720
        return RTCCameraVideoCapturer.supportedFormats(for: device).min { lhs, rhs in
            let left = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let right = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            let leftPixels = left.width * left.height
            let rightPixels = right.width * right.height
            let leftPenalty = leftPixels >= targetPixels ? leftPixels - targetPixels : targetPixels - leftPixels + targetPixels
            let rightPenalty = rightPixels >= targetPixels ? rightPixels - targetPixels : targetPixels - rightPixels + targetPixels
            return leftPenalty < rightPenalty
        }
    }

    private static func preferredFPS(for format: AVCaptureDevice.Format) -> Int {
        min(30, format.videoSupportedFrameRateRanges.map { Int($0.maxFrameRate) }.max() ?? 30)
    }

    private func startScreenShare() {
        guard let source = localVideoSource, let localVideoTrack, !isScreenSharing else { return }
        deviceBroadcastTask?.cancel()
        deviceBroadcastTask = nil
        isUsingDeviceBroadcast = false
        localVideoCapturer?.stopCapture()
        let capturer = RTCVideoCapturer(delegate: source)
        screenVideoCapturer = capturer
        screenRecorder.isMicrophoneEnabled = false
        screenRecorder.startCapture { [weak self, weak source, weak capturer] sampleBuffer, sampleType, error in
            guard error == nil,
                  sampleType == .video,
                  let source,
                  let capturer,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            else { return }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let timestampNs = Int64(timestamp.seconds * 1_000_000_000)
            let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
            let frame = RTCVideoFrame(buffer: rtcBuffer, rotation: ._0, timeStampNs: timestampNs)
            source.capturer(capturer, didCapture: frame)
            Task { @MainActor [weak self] in
                self?.isVideoEnabled = true
                localVideoTrack.isEnabled = true
            }
        } completionHandler: { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.log.error("screen share capture failed: \(PrivacyRedactor.error(error))")
                    self.screenVideoCapturer = nil
                    if let capturer = self.localVideoCapturer, self.isVideoEnabled {
                        self.startVideoCapture(capturer)
                    }
                    return
                }
                self.isScreenSharing = true
                self.isVideoEnabled = true
                self.localVideoTrack?.isEnabled = true
                self.updateDiagnostics { _ in }
            }
        }
    }

    private func startDeviceBroadcastScreenShare() {
        guard let source = localVideoSource, let localVideoTrack else { return }
        let capturer = RTCVideoCapturer(delegate: source)
        screenVideoCapturer = capturer
        isUsingDeviceBroadcast = true
        isScreenSharing = true
        isVideoEnabled = true
        localVideoTrack.isEnabled = true
        deviceBroadcastFrameModifiedAt = nil
        updateDiagnostics { _ in }

        deviceBroadcastTask?.cancel()
        deviceBroadcastTask = Task.detached(priority: .utility) { [weak self, weak source, weak capturer] in
            while !Task.isCancelled {
                let lastModifiedAt = await MainActor.run { self?.deviceBroadcastFrameModifiedAt }
                if let frame = Self.loadLatestDeviceBroadcastFrame(after: lastModifiedAt) {
                    await MainActor.run {
                        guard let self, let source, let capturer, self.isUsingDeviceBroadcast else { return }
                        if self.deviceBroadcastFrameModifiedAt == nil {
                            self.localVideoCapturer?.stopCapture()
                        }
                        self.deviceBroadcastFrameModifiedAt = frame.modifiedAt
                        self.publishDeviceBroadcastFrame(frame.pixelBuffer, source: source, capturer: capturer)
                    }
                }
                try? await Task.sleep(for: .milliseconds(70))
            }
        }
    }

    private func stopScreenShare(restartCamera: Bool) {
        guard isScreenSharing || screenVideoCapturer != nil else { return }
        if isUsingDeviceBroadcast {
            deviceBroadcastTask?.cancel()
            deviceBroadcastTask = nil
            screenVideoCapturer = nil
            isUsingDeviceBroadcast = false
            // Don't leave the last screen frame lying in the App Group container.
            if let url = Self.broadcastFrameURL() { try? FileManager.default.removeItem(at: url) }
            isScreenSharing = false
            updateDiagnostics { _ in }
            if restartCamera, isVideoEnabled, let capturer = localVideoCapturer {
                startVideoCapture(capturer)
            }
            return
        }
        screenRecorder.stopCapture { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.log.error("screen share stop failed: \(PrivacyRedactor.error(error))")
                }
                self.screenVideoCapturer = nil
                self.isScreenSharing = false
                self.updateDiagnostics { _ in }
                if restartCamera, self.isVideoEnabled, let capturer = self.localVideoCapturer {
                    self.startVideoCapture(capturer)
                }
            }
        }
    }

    private func stopVideoCapture() {
        stopScreenShare(restartCamera: false)
        deviceBroadcastTask?.cancel()
        deviceBroadcastTask = nil
        localVideoCapturer?.stopCapture()
        localVideoSource = nil
        localVideoCapturer = nil
        localVideoTrack = nil
        remoteVideoTrack = nil
    }

    private func publishDeviceBroadcastFrame(_ pixelBuffer: CVPixelBuffer, source: RTCVideoSource, capturer: RTCVideoCapturer) {
        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let frame = RTCVideoFrame(
            buffer: rtcBuffer,
            rotation: ._0,
            timeStampNs: Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        )
        source.capturer(capturer, didCapture: frame)
    }

    nonisolated private static func loadLatestDeviceBroadcastFrame(after lastModifiedAt: Date?) -> (modifiedAt: Date, pixelBuffer: CVPixelBuffer)? {
        guard let url = broadcastFrameURL(),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modifiedAt = attributes[.modificationDate] as? Date,
              modifiedAt != lastModifiedAt,
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data)?.cgImage,
              let pixelBuffer = pixelBuffer(from: image)
        else { return nil }
        return (modifiedAt, pixelBuffer)
    }

    nonisolated private static func broadcastFrameURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: broadcastAppGroupId)?
            .appendingPathComponent(broadcastFrameFilename)
    }

    nonisolated private static func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let width = image.width
        let height = image.height
        let attributes = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ] as CFDictionary
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes,
            &pixelBuffer
        ) == kCVReturnSuccess,
            let pixelBuffer
        else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }

    private func defaultConstraints(kind: CallKind) -> RTCMediaConstraints {
        var mandatory = [
            "OfferToReceiveAudio": "true",
            "OfferToReceiveVideo": kind == .video ? "true" : "false",
        ]
        if kind == .video {
            mandatory["minWidth"] = "1280"
            mandatory["minHeight"] = "720"
            mandatory["minFrameRate"] = "24"
        }
        return RTCMediaConstraints(
            mandatoryConstraints: mandatory,
            optionalConstraints: kind == .video ? ["googHighStartBitrate": "true"] : nil
        )
    }

    private func parseIce(_ json: String) -> RTCIceCandidate? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sdp = dict["candidate"] as? String,
              let sdpMid = dict["sdpMid"] as? String,
              let sdpMLineIndex = dict["sdpMLineIndex"] as? Int32
        else { return nil }
        return RTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
    }

    private func iceJSON(_ candidate: RTCIceCandidate) -> String {
        let dict: [String: Any] = [
            "candidate": candidate.sdp,
            "sdpMid": candidate.sdpMid ?? "",
            "sdpMLineIndex": candidate.sdpMLineIndex,
        ]
        return (try? String(data: JSONSerialization.data(withJSONObject: dict), encoding: .utf8)) ?? "{}"
    }

    // MARK: - Group calls

    /// Initiates a group call: sends GROUP_RING to all participants.
    func startGroupCall(groupId: String, groupName: String, participants: [String], kind: CallKind = .audio) async {
        guard case .idle = state, !isInGroupCall else { return }
        // Relay-only mode: refuse up front if no TURN server is reachable.
        guard await makeRTCConfiguration() != nil else {
            groupCallFailureMessage = peerConnectionFailureReason ?? Self.noRelayServerMessage
            peerConnectionFailureReason = nil
            return
        }
        let callId = UUID().uuidString
        groupCallId = callId
        groupCallGroupId = groupId
        let roster = groupMembersResolver?(groupId) ?? participants
        groupCallMembers = Set(roster.filter { $0 != ownAccountId && !$0.isEmpty })
        groupCallKind = kind
        groupCallDisplayName = groupName
        isInGroupCall = true

        if kind == .video { await requestCameraAccessIfNeeded() }
        configureAudioSessionForCall()
        // Group calls bypass CallKit so the audio session must be activated manually.
        // (1:1 calls get this via provider(_:didActivate:); here we own the session.)
        let avSession = AVAudioSession.sharedInstance()
        try? avSession.setActive(true)
        RTCAudioSession.sharedInstance().audioSessionDidActivate(avSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = true
        setupGroupLocalMedia(kind: kind)

        var ring = Relay_Content_CallMessage()
        ring.type = .groupRing
        ring.callID = callId
        ring.groupID = groupId
        ring.participants = participants
        ring.ice = Self.metadataJSON(kind: kind)
        await onSendGroupCallMessage?(ring, participants)
        // Do NOT send VoIP pushes for group calls. GROUP_RING is non-ephemeral
        // so the relay queues it and delivers via WebSocket / regular APNs.
        // VoIP pushes would trigger PushKitDelegate → reportIncomingCall →
        // state = .incoming, blocking the GROUP_RING WebSocket path entirely.
    }

    /// Accepts an incoming group call ring.
    func joinGroupCall() async {
        guard isInGroupCall, let info = groupRingInfo else { return }
        guard await makeRTCConfiguration() != nil else {
            groupCallFailureMessage = peerConnectionFailureReason ?? Self.noRelayServerMessage
            peerConnectionFailureReason = nil
            stopRingtone()
            endGroupCallCleanup()
            return
        }
        groupRingInfo = nil
        stopRingtone()
        groupCallDisplayName = info.callerName

        if groupCallKind == .video { await requestCameraAccessIfNeeded() }
        configureAudioSessionForCall()
        // Activate audio session manually (no CallKit in group calls).
        let avSession = AVAudioSession.sharedInstance()
        try? avSession.setActive(true)
        RTCAudioSession.sharedInstance().audioSessionDidActivate(avSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = true
        setupGroupLocalMedia(kind: groupCallKind)

        var join = Relay_Content_CallMessage()
        join.type = .groupJoin
        join.callID = info.callId
        join.groupID = info.groupId
        let targets = Array(groupCallMembers.union([info.callerAccount])).filter { $0 != ownAccountId }
        await onSendGroupCallMessage?(join, targets)
    }

    /// Declines an incoming group call without joining.
    func declineGroupCall() {
        guard isInGroupCall, groupRingInfo != nil else { return }
        groupRingInfo = nil
        stopRingtone()
        endGroupCallCleanup()
    }

    /// Leaves an active group call, notifying all current peers.
    func leaveGroupCall() {
        guard isInGroupCall else { return }
        stopRingtone()
        if let callId = groupCallId, let groupId = groupCallGroupId, !groupPeers.isEmpty {
            let accounts = Array(groupPeers.keys)
            var leave = Relay_Content_CallMessage()
            leave.type = .groupLeave
            leave.callID = callId
            leave.groupID = groupId
            Task { await self.onSendGroupCallMessage?(leave, accounts) }
        }
        endGroupCallCleanup()
    }

    /// A group-call signal is honored only when it names the current group call
    /// (call id + group id) and comes from a member of that group's locally
    /// stored roster.
    private func isFromCurrentGroupCallMember(_ msg: Relay_Content_CallMessage, account: String) -> Bool {
        guard isInGroupCall,
              !account.isEmpty, account != ownAccountId,
              let callId = groupCallId, !callId.isEmpty, callId == msg.callID,
              groupCallMembers.contains(account)
        else { return false }
        if !msg.groupID.isEmpty, msg.groupID != groupCallGroupId { return false }
        return true
    }

    private func handleGroupCallMessage(_ msg: Relay_Content_CallMessage, from account: String) async {
        switch msg.type {
        case .groupRing:
            // Only a member of a group we know may ring it, and never a blocked one.
            guard !account.isEmpty, !msg.groupID.isEmpty, !msg.callID.isEmpty,
                  let roster = groupMembersResolver?(msg.groupID),
                  roster.contains(account),
                  isBlockedAccount?(account) != true
            else {
                log.warning("ignoring GROUP_RING from a non-member or unknown group")
                return
            }
            // If an anonymous VoIP push registered this same call id, it was
            // never a real 1:1 call — drop the placeholder and ring as a group.
            if case .incoming(let existingId, _, _) = state, existingId == msg.callID, isAwaitingCallerIdentity {
                endUnverifiedCall()
            }
            guard !isInGroupCall, case .idle = state else { return }
            let displayName = nameResolver?(account) ?? "Unknown"
            groupCallId = msg.callID
            groupCallGroupId = msg.groupID
            groupCallMembers = Set(roster.filter { $0 != ownAccountId && !$0.isEmpty })
            groupCallKind = Self.callKind(fromMetadata: msg.ice) ?? .audio
            isInGroupCall = true
            groupRingInfo = GroupRingInfo(
                callId: msg.callID, groupId: msg.groupID,
                callerAccount: account, callerName: displayName,
                // Never trust the ringer's participant list — use our roster.
                participants: Array(groupCallMembers), kind: groupCallKind
            )
            startRingtone()

        case .groupJoin:
            guard isFromCurrentGroupCallMember(msg, account: account),
                  groupRingInfo == nil,   // we haven't accepted the ring yet
                  groupPeers[account] == nil
            else { return }
            let peerName = nameResolver?(account) ?? "Unknown"
            groupPeers[account] = GroupCallPeer(peerAccount: account, peerName: peerName)
            await initiateGroupPeerOffer(toPeer: account, callId: msg.callID)

        case .groupLeave:
            guard isFromCurrentGroupCallMember(msg, account: account) else { return }
            closeGroupPeerConnection(forAccount: account)
            groupPeers.removeValue(forKey: account)
            groupPeerDelegates.removeValue(forKey: account)

        case .offer:
            // Mesh OFFER from a group peer — only process if addressed to us.
            guard isFromCurrentGroupCallMember(msg, account: account),
                  groupRingInfo == nil,   // not until we've actually joined
                  msg.targetAccount == ownAccountId
            else { return }
            let peerName = nameResolver?(account) ?? "Unknown"
            if groupPeers[account] == nil {
                groupPeers[account] = GroupCallPeer(peerAccount: account, peerName: peerName)
            }
            await handleGroupPeerOffer(msg, from: account)

        case .answer:
            guard isFromCurrentGroupCallMember(msg, account: account), groupPeers[account] != nil else { return }
            await handleGroupPeerAnswer(msg, from: account)

        case .ice:
            guard isFromCurrentGroupCallMember(msg, account: account), groupPeers[account] != nil else { return }
            await handleGroupPeerICE(msg, from: account)

        case .hangup, .busy:
            guard isFromCurrentGroupCallMember(msg, account: account) else { return }
            closeGroupPeerConnection(forAccount: account)
            groupPeers.removeValue(forKey: account)
            groupPeerDelegates.removeValue(forKey: account)
            if groupPeers.isEmpty { endGroupCallCleanup() }

        case .linkJoinRequest:
            await handleLinkJoinRequest(msg, from: account)
        case .linkAdmit:
            await handleLinkAdmit(msg, from: account)
        case .linkRoster:
            guard isInGroupCall, groupCallId == msg.callID, groupCallGroupId == Self.linkGroupId(msg.callID),
                  account == linkHostAccount, account != ownAccountId
            else { return }
            groupCallMembers = Set((msg.participants + [account]).filter { $0 != ownAccountId && !$0.isEmpty })
        case .linkDeny:
            guard var out = outgoingLinkJoin, out.callId == msg.callID, out.hostAccount == account,
                  out.status == .waiting
            else { return }
            out.status = .denied
            outgoingLinkJoin = out

        default:
            break
        }
    }

    // MARK: - Call links
    //
    // A call link is https://relaymsg.app/call/<callId>#<hostAccount>.<secret>.
    // Everything after "#" stays on the phone (browsers and the app never send
    // it to a server). Opening the link sends LINK_JOIN_REQUEST with the secret
    // to the host, end-to-end encrypted. The host admits or denies; an admitted
    // joiner is told who else is in the call (LINK_ADMIT), the others are told
    // about the joiner (LINK_ROSTER), and the normal group-call mesh takes over.
    // The relay keeps no call state; the link only works while the host can
    // answer.

    nonisolated static func linkGroupId(_ callId: String) -> String { "link:" + callId }

    /// Parses a call link URL (https://relaymsg.app/call/… or relay://call/…).
    nonisolated static func parseCallLink(_ url: URL) -> (callId: String, host: String, secret: String)? {
        let parts = url.pathComponents.filter { $0 != "/" }
        let callId: String?
        if url.scheme == "relay", url.host == "call" {
            callId = parts.first
        } else if url.host == "relaymsg.app", parts.count >= 2, parts[0] == "call" {
            callId = parts[1]
        } else {
            callId = nil
        }
        guard let callId, UUID(uuidString: callId) != nil,
              let fragment = url.fragment, let dot = fragment.firstIndex(of: ".")
        else { return nil }
        let host = String(fragment[..<dot])
        let secret = String(fragment[fragment.index(after: dot)...])
        guard UUID(uuidString: host) != nil || !host.isEmpty, secret.count >= 16 else { return nil }
        return (callId, host, secret)
    }

    private func sendLinkSignal(_ type: Relay_Content_CallMessage.TypeEnum, callId: String,
                                to accounts: [String], participants: [String] = [], sdp: String = "") async {
        guard !accounts.isEmpty else { return }
        var msg = Relay_Content_CallMessage()
        msg.type = type
        msg.callID = callId
        msg.groupID = Self.linkGroupId(callId)
        msg.participants = participants
        msg.sdp = sdp
        msg.ice = Self.metadataJSON(kind: groupCallKind)
        await onSendGroupCallMessage?(msg, accounts)
    }

    /// Activates audio (group calls bypass CallKit) and local media.
    private func beginGroupMedia(kind: CallKind) async {
        if kind == .video { await requestCameraAccessIfNeeded() }
        configureAudioSessionForCall()
        let avSession = AVAudioSession.sharedInstance()
        try? avSession.setActive(true)
        RTCAudioSession.sharedInstance().audioSessionDidActivate(avSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = true
        setupGroupLocalMedia(kind: kind)
    }

    /// Host: starts the call behind one of our links. Nobody is rung; people
    /// join by opening the link.
    @discardableResult
    func startLinkCall(callId: String, name: String, kind: CallKind = .audio) async -> Bool {
        guard case .idle = state, !isInGroupCall else { return false }
        guard await makeRTCConfiguration() != nil else {
            groupCallFailureMessage = peerConnectionFailureReason ?? Self.noRelayServerMessage
            peerConnectionFailureReason = nil
            return false
        }
        groupCallId = callId
        groupCallGroupId = Self.linkGroupId(callId)
        groupCallMembers = []
        groupCallKind = kind
        groupCallDisplayName = name
        linkHostAccount = ownAccountId
        isInGroupCall = true
        await beginGroupMedia(kind: kind)
        return true
    }

    private func handleLinkJoinRequest(_ msg: Relay_Content_CallMessage, from account: String) async {
        guard !account.isEmpty, account != ownAccountId,
              msg.groupID == Self.linkGroupId(msg.callID),
              let secret = callLinkSecretResolver?(msg.callID),
              Self.constantTimeEquals(secret, msg.sdp),
              isBlockedAccount?(account) != true
        else { return }
        // Busy in a different call: say no rather than leave them waiting.
        let inThisCall = isInGroupCall && groupCallId == msg.callID
        let idle: Bool = { if case .idle = state { return !isInGroupCall } else { return false } }()
        guard inThisCall || idle else {
            await sendLinkSignal(.linkDeny, callId: msg.callID, to: [account])
            return
        }
        guard !groupCallMembers.contains(account),
              !linkJoinRequests.contains(where: { $0.account == account && $0.callId == msg.callID })
        else { return }
        linkJoinRequests.append(LinkJoinRequest(
            account: account, name: nameResolver?(account) ?? "Someone with your link", callId: msg.callID
        ))
    }

    /// Host: lets someone in, starting the call first if we aren't in it yet.
    func admitLinkJoin(_ request: LinkJoinRequest) async {
        linkJoinRequests.removeAll { $0 == request }
        if !(isInGroupCall && groupCallId == request.callId) {
            let name = callLinkNameResolver?(request.callId) ?? "Call link"
            guard await startLinkCall(callId: request.callId, name: name) else { return }
        }
        guard groupCallId == request.callId, let me = ownAccountId else { return }
        let others = Array(groupCallMembers)
        groupCallMembers.insert(request.account)
        // Existing members first, so they accept the newcomer's GROUP_JOIN.
        await sendLinkSignal(.linkRoster, callId: request.callId, to: others,
                             participants: Array(groupCallMembers) + [me])
        await sendLinkSignal(.linkAdmit, callId: request.callId, to: [request.account], participants: others)
    }

    func denyLinkJoin(_ request: LinkJoinRequest) {
        linkJoinRequests.removeAll { $0 == request }
        Task { await sendLinkSignal(.linkDeny, callId: request.callId, to: [request.account]) }
    }

    /// Joiner: asks the link's host to let us in.
    func requestToJoinLink(callId: String, hostAccount: String, secret: String) async {
        guard case .idle = state, !isInGroupCall, hostAccount != ownAccountId else { return }
        let request = OutgoingLinkJoin(callId: callId, hostAccount: hostAccount, secret: secret,
                                       hostName: nameResolver?(hostAccount) ?? "the host", status: .waiting)
        outgoingLinkJoin = request
        await sendLinkSignal(.linkJoinRequest, callId: callId, to: [hostAccount], sdp: secret)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            guard let self, var out = self.outgoingLinkJoin, out.callId == callId, out.status == .waiting else { return }
            out.status = .noAnswer
            self.outgoingLinkJoin = out
        }
    }

    func cancelLinkJoin() { outgoingLinkJoin = nil }

    private func handleLinkAdmit(_ msg: Relay_Content_CallMessage, from account: String) async {
        guard let out = outgoingLinkJoin, out.callId == msg.callID, out.hostAccount == account,
              out.status == .waiting, case .idle = state, !isInGroupCall
        else { return }
        outgoingLinkJoin = nil
        guard await makeRTCConfiguration() != nil else {
            groupCallFailureMessage = peerConnectionFailureReason ?? Self.noRelayServerMessage
            peerConnectionFailureReason = nil
            return
        }
        groupCallId = msg.callID
        groupCallGroupId = Self.linkGroupId(msg.callID)
        linkHostAccount = account
        groupCallMembers = Set((msg.participants + [account]).filter { $0 != ownAccountId && !$0.isEmpty })
        groupCallKind = Self.callKind(fromMetadata: msg.ice) ?? .audio
        groupCallDisplayName = "\(out.hostName)'s call"
        isInGroupCall = true
        await beginGroupMedia(kind: groupCallKind)

        var join = Relay_Content_CallMessage()
        join.type = .groupJoin
        join.callID = msg.callID
        join.groupID = Self.linkGroupId(msg.callID)
        await onSendGroupCallMessage?(join, Array(groupCallMembers))
    }

    private nonisolated static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    private func initiateGroupPeerOffer(toPeer account: String, callId: String) async {
        guard let pc = await makeGroupPeerConnection(forAccount: account) else { return }
        groupPeers[account]?.peerConnection = pc
        if let audioTrack = groupCallLocalAudioTrack { pc.add(audioTrack, streamIds: ["grp"]) }
        if let videoTrack = groupCallLocalVideoTrack { pc.add(videoTrack, streamIds: ["grp"]) }

        guard let offer = try? await pc.offer(for: defaultConstraints(kind: groupCallKind)) else { return }
        try? await pc.setLocalDescription(offer)

        var msg = Relay_Content_CallMessage()
        msg.type = .offer
        msg.callID = callId
        msg.groupID = groupCallGroupId ?? ""
        msg.sdp = Self.sanitizeSDP(offer.sdp)
        msg.targetAccount = account
        _ = await onSendCallMessage?(msg, account)
    }

    private func handleGroupPeerOffer(_ msg: Relay_Content_CallMessage, from account: String) async {
        // A re-offer (reconnection) replaces the old connection.
        if groupPeers[account]?.peerConnection != nil { markReconnecting() }
        closeGroupPeerConnection(forAccount: account)
        groupPeers[account]?.hasRemoteDescription = false
        groupPeers[account]?.pendingCandidates = []
        guard let pc = await makeGroupPeerConnection(forAccount: account) else { return }
        groupPeers[account]?.peerConnection = pc
        if let audioTrack = groupCallLocalAudioTrack { pc.add(audioTrack, streamIds: ["grp"]) }
        if let videoTrack = groupCallLocalVideoTrack { pc.add(videoTrack, streamIds: ["grp"]) }

        let desc = RTCSessionDescription(type: .offer, sdp: msg.sdp)
        do {
            try await pc.setRemoteDescription(desc)
            groupPeers[account]?.hasRemoteDescription = true
            let queued = groupPeers[account]?.pendingCandidates ?? []
            groupPeers[account]?.pendingCandidates.removeAll()
            for c in queued { try? await pc.add(c) }

            let answer = try await pc.answer(for: defaultConstraints(kind: groupCallKind))
            try await pc.setLocalDescription(answer)

            var reply = Relay_Content_CallMessage()
            reply.type = .answer
            reply.callID = msg.callID
            reply.groupID = msg.groupID
            reply.sdp = Self.sanitizeSDP(answer.sdp)
            reply.targetAccount = account
            _ = await onSendCallMessage?(reply, account)
        } catch {
            log.error("group offer failed: \(PrivacyRedactor.error(error))")
            groupPeers.removeValue(forKey: account)
            groupPeerDelegates.removeValue(forKey: account)
        }
    }

    private func handleGroupPeerAnswer(_ msg: Relay_Content_CallMessage, from account: String) async {
        guard let pc = groupPeers[account]?.peerConnection else { return }
        do {
            try await pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: msg.sdp))
            groupPeers[account]?.hasRemoteDescription = true
            let queued = groupPeers[account]?.pendingCandidates ?? []
            groupPeers[account]?.pendingCandidates.removeAll()
            for c in queued { try? await pc.add(c) }
        } catch {
            log.error("group answer failed: \(PrivacyRedactor.error(error))")
        }
    }

    private func handleGroupPeerICE(_ msg: Relay_Content_CallMessage, from account: String) async {
        guard let candidate = parseIce(msg.ice) else { return }
        if let pc = groupPeers[account]?.peerConnection, groupPeers[account]?.hasRemoteDescription == true {
            try? await pc.add(candidate)
        } else {
            groupPeers[account]?.pendingCandidates.append(candidate)
        }
    }

    private func makeGroupPeerConnection(forAccount account: String) async -> RTCPeerConnection? {
        let delegate = GroupPCDelegate(peerAccount: account)
        delegate.onICECandidate = { [weak self] candidate in
            // Relay-only mode: never let a host/srflx/prflx candidate (which
            // carries a real IP address) leave the device.
            if Self.isPrivateCallModeEnabled, !Self.isRelayCandidate(candidate.sdp) { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                var msg = Relay_Content_CallMessage()
                msg.type = .ice
                msg.callID = self.groupCallId ?? ""
                msg.groupID = self.groupCallGroupId ?? ""
                msg.ice = self.iceJSON(candidate)
                msg.targetAccount = account
                _ = await self.onSendCallMessage?(msg, account)
            }
        }
        delegate.onConnectionStateChanged = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .connected, .completed:
                    self.groupPeers[account]?.isConnected = true
                    self.groupReconnectTasks[account]?.cancel()
                    self.groupReconnectTasks[account] = nil
                    // Re-assert enabled in case the audio session was briefly
                    // interrupted between join and first peer connect.
                    RTCAudioSession.sharedInstance().isAudioEnabled = true
                case .failed, .disconnected:
                    self.groupPeers[account]?.isConnected = false
                    self.scheduleGroupReconnect(account)
                default:
                    break
                }
            }
        }
        delegate.onTrackAdded = { [weak self] track in
            Task { @MainActor [weak self] in
                self?.groupPeers[account]?.remoteVideoTrack = track
            }
        }
        groupPeerDelegates[account] = delegate

        guard let config = await makeRTCConfiguration() else {
            // Relay-only mode without a TURN server: never connect directly.
            groupPeers.removeValue(forKey: account)
            groupPeerDelegates.removeValue(forKey: account)
            return nil
        }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        return factory.peerConnection(with: config, constraints: constraints, delegate: delegate)
    }

    private func setupGroupLocalMedia(kind: CallKind) {
        let audioSource = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        groupCallLocalAudioTrack = factory.audioTrack(with: audioSource, trackId: "grp-audio0")
        guard kind == .video else { return }
        let videoSource = factory.videoSource()
        let capturer = RTCCameraVideoCapturer(delegate: videoSource)
        videoSource.adaptOutputFormat(toWidth: 640, height: 480, fps: 24)
        groupCallLocalVideoTrack = factory.videoTrack(with: videoSource, trackId: "grp-video0")
        groupCallLocalVideoSource = videoSource
        groupCallLocalVideoCapturer = capturer
        isVideoEnabled = true
        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == .front })
                ?? RTCCameraVideoCapturer.captureDevices().first,
              let format = Self.preferredVideoFormat(for: device) else { return }
        capturer.startCapture(with: device, format: format, fps: min(24, Self.preferredFPS(for: format)))
    }

    private func closeGroupPeerConnection(forAccount account: String) {
        groupPeers[account]?.peerConnection?.close()
    }

    private func endGroupCallCleanup() {
        for task in groupReconnectTasks.values { task.cancel() }
        groupReconnectTasks.removeAll()
        reconnectingUntil = nil
        for peer in groupPeers.values { peer.peerConnection?.close() }
        groupPeers.removeAll()
        groupPeerDelegates.removeAll()
        groupCallLocalVideoCapturer?.stopCapture()
        groupCallLocalVideoCapturer = nil
        groupCallLocalVideoSource = nil
        groupCallLocalVideoTrack = nil
        groupCallLocalAudioTrack = nil
        isInGroupCall = false
        groupCallId = nil
        groupCallGroupId = nil
        groupCallMembers = []
        groupCallKind = .audio
        groupCallDisplayName = "Group Call"
        groupRingInfo = nil
        linkHostAccount = nil
        isVideoEnabled = true
        // Return the audio session to idle so other apps can use the mic/speaker.
        RTCAudioSession.sharedInstance().isAudioEnabled = false
        let avSession = AVAudioSession.sharedInstance()
        RTCAudioSession.sharedInstance().audioSessionDidDeactivate(avSession)
        try? avSession.setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - RTCPeerConnectionDelegate

extension CallManager: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        // Log the candidate type so it's easy to see in the console whether
        // TURN relay candidates are actually being gathered.
        let sdp = candidate.sdp
        let candidateType = sdp.contains("typ relay") ? "relay(TURN)" :
                            sdp.contains("typ srflx") ? "srflx(STUN)" :
                            sdp.contains("typ prflx") ? "prflx" : "host"
        // Relay-only mode: drop any candidate that isn't TURN-relayed before it
        // can be sent — host/srflx/prflx candidates carry this device's IPs.
        let dropForPrivacy = CallManager.isPrivateCallModeEnabled && !CallManager.isRelayCandidate(sdp)
        Task { @MainActor in
            log.info("ICE candidate gathered type=\(candidateType)")
            if dropForPrivacy {
                log.info("dropping non-relay ICE candidate (relay-only mode)")
                return
            }
            // Use stored values — these are set at call start and valid through
            // all state transitions (.outgoing → .connecting → .active).
            guard let peerAccount = storedCallPeer, !peerAccount.isEmpty,
                  let callId = storedCallId, !callId.isEmpty else { return }
            let json = iceJSON(candidate)
            var msg = Relay_Content_CallMessage()
            msg.type = .ice
            msg.callID = callId
            msg.ice = json
            _ = await onSendCallMessage?(msg, peerAccount)
        }
    }

    nonisolated func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange state: RTCSignalingState) {
        Task { @MainActor in
            updateDiagnostics { $0.signalingState = String(describing: state) }
        }
    }
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        Task { @MainActor in
            remoteVideoTrack = stream.videoTracks.first
            updateDiagnostics { _ in }
        }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        Task { @MainActor in
            if remoteVideoTrack === stream.videoTracks.first {
                remoteVideoTrack = nil
                updateDiagnostics { _ in }
            }
        }
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd receiver: RTCRtpReceiver,
        streams mediaStreams: [RTCMediaStream]
    ) {
        Task { @MainActor in
            if let track = receiver.track as? RTCVideoTrack {
                remoteVideoTrack = track
                storedCallKind = .video
                updateDiagnostics { _ in }
            }
        }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange state: RTCIceConnectionState) {
        Task { @MainActor in
            updateDiagnostics { $0.iceConnectionState = String(describing: state) }
            switch state {
            case .connected, .completed:
                iceRecoveryTask?.cancel()
                iceRecoveryTask = nil
                iceRestartTask?.cancel()
                iceRestartTask = nil
                isReconnecting = false
                // Media is connected now. Keep both caller and callee in
                // .connecting until this point so the UI and CallKit do not
                // claim the call is live while ICE is still negotiating.
                configureAudioSessionForCall()
                RTCAudioSession.sharedInstance().isAudioEnabled = true
                guard case .connecting = self.state else { break }
                let startedAt = Date()
                storedCallConnectedAt = startedAt
                let callId = storedCallId ?? UUID().uuidString
                self.state = .active(callId: callId, startedAt: startedAt)
                if !wasIncomingCall, hasCallKitReport, let uuid = activeCallUUID {
                    provider.reportOutgoingCall(with: uuid, connectedAt: startedAt)
                }
            case .failed where storedCallConnectedAt != nil,
                 .disconnected where storedCallConnectedAt != nil:
                // Was connected and lost it — e.g. our TURN server went down.
                // Reconnect with fresh servers (the relay hands out the backup
                // TURN once it notices); only give up if that fails too.
                isReconnecting = true
                startIceRestart()
                scheduleIceFailure(reason: "Call connection was lost.", delay: .seconds(40))
            case .failed:
                scheduleIceFailure(reason: "Couldn’t connect audio.", delay: .seconds(3))
            case .disconnected:
                scheduleIceFailure(reason: "Call connection was interrupted.", delay: .seconds(10))
            default:
                break
            }
        }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange state: RTCIceGatheringState) {
        Task { @MainActor in
            updateDiagnostics { $0.iceGatheringState = String(describing: state) }
        }
    }
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

// MARK: - CXProviderDelegate

extension CallManager: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {}

    // Required: CallKit calls this when requestTransaction(with: CXStartCallAction) is
    // processed. Without fulfilling the action, CallKit treats the outgoing call as
    // failed, never activates the audio session, and eventually fires CXEndCallAction.
    // setConfiguration before fulfill is the iOS 18.4.1+ workaround for unreliable
    // didActivate on outgoing calls — same fix applied to incoming in reportIncomingCall.
    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in
            provider.configuration = makeProviderConfiguration()
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            await callKitAnswered()
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            terminate(fromRemote: false, reportToCallKit: false)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor in
            isMuted = action.isMuted
            localAudioTrack?.isEnabled = !isMuted
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { @MainActor in
            configureAudioSessionForCall()
            RTCAudioSession.sharedInstance().audioSessionDidActivate(audioSession)
            RTCAudioSession.sharedInstance().isAudioEnabled = true
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor in
            RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
            RTCAudioSession.sharedInstance().isAudioEnabled = false
        }
    }
}

// MARK: - GroupPCDelegate

final class GroupPCDelegate: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    var onICECandidate: ((RTCIceCandidate) -> Void)?
    var onConnectionStateChanged: ((RTCIceConnectionState) -> Void)?
    var onTrackAdded: ((RTCVideoTrack) -> Void)?
    private let peerAccount: String

    init(peerAccount: String) { self.peerAccount = peerAccount }

    func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onICECandidate?(candidate)
    }
    func peerConnection(_ pc: RTCPeerConnection, didChange state: RTCIceConnectionState) {
        onConnectionStateChanged?(state)
    }
    func peerConnection(_ pc: RTCPeerConnection, didAdd receiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        if let track = receiver.track as? RTCVideoTrack { onTrackAdded?(track) }
    }
    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange state: RTCSignalingState) {}
    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange state: RTCIceGatheringState) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
