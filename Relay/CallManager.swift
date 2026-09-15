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
    var onTriggerPush: ((String, String, String, CallKind) async -> Void)?  // (account, callId, name, kind)

    // MARK: Group call state
    private(set) var isInGroupCall = false
    private(set) var groupPeers: [String: GroupCallPeer] = [:]
    private(set) var groupRingInfo: GroupRingInfo? = nil
    private(set) var groupCallKind: CallKind = .audio
    private(set) var groupCallDisplayName: String = "Group Call"
    var ownAccountId: String?
    private var groupCallId: String?
    private var groupCallGroupId: String?
    private var groupCallLocalAudioTrack: RTCAudioTrack?
    private var groupCallLocalVideoSource: RTCVideoSource?
    private var groupCallLocalVideoCapturer: RTCCameraVideoCapturer?
    private(set) var groupCallLocalVideoTrack: RTCVideoTrack?
    private var groupPeerDelegates: [String: GroupPCDelegate] = [:]
    /// Resolves an account UUID to a human display name for CallKit / CallView labels.
    var nameResolver: ((String) -> String)?
    /// Local user's display name for the caller label in VoIP pushes.
    var localDisplayNameProvider: (() -> String)?
    /// Persists call records after the call reaches a terminal state.
    var onRecordCall: ((StoredCall) -> Void)?
    /// Returns fresh TURN credentials from the server; nil if TURN not configured.
    var onFetchTurnCredentials: (() async throws -> TurnCredentials?)?

    /// When true, forces TURN-relay-only ICE policy so the peer never sees the
    /// device's real IP. Default ON; enforced only when a TURN server is actually
    /// available (see `shouldForceRelay`) so calls still connect if TURN is down.
    var privateCallMode: Bool {
        get { UserDefaults.standard.object(forKey: "relay.privateCallMode") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "relay.privateCallMode") }
    }

    /// Relay-only policy is safe only when we actually have a TURN server; with
    /// `.relay` and no TURN, a call gathers no candidates and never connects.
    private func shouldForceRelay(_ servers: [RTCIceServer]) -> Bool {
        guard privateCallMode else { return false }
        return servers.contains { $0.urlStrings.contains { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") } }
    }

    // Short-lived TURN credential cache (avoids a fetch on every peer-connection creation).
    private var cachedTurnCredentials: (creds: TurnCredentials, expiresAt: Date)?

    private var peerConnection: RTCPeerConnection?
    private var hasAnsweredCall = false
    private var wasIncomingCall = false   // true when we are the callee
    private var callTimeoutTask: Task<Void, Never>?
    private var iceRecoveryTask: Task<Void, Never>?
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

    nonisolated private static let broadcastAppGroupId = "group.com.morgandaly.RelayMessenger"
    nonisolated private static let broadcastFrameFilename = "RelayBroadcastFrame.jpg"
    private let log = Logger(subsystem: "com.morgandaly.RelayMessenger", category: "CallManager")

    var needsSignalingConnection: Bool {
        if isInGroupCall { return true }
        switch state {
        case .idle, .ended, .failed:
            return false
        case .outgoing, .incoming, .connecting, .active:
            return true
        }
    }

    // The provider config is stored so we can call setConfiguration() before
    // reportNewIncomingCall as the iOS 18.4.1+ workaround for unreliable didActivate.
    private let providerConfig: CXProviderConfiguration

    override init() {
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)

        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        providerConfig = config
        provider = CXProvider(configuration: config)
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

    func startCall(peerAccount: String, peerName: String, kind: CallKind = .audio) async {
        guard case .idle = state else { return }
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

        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: peerName))
        action.isVideo = kind == .video
        do {
            try await callController.requestTransaction(with: action)
        } catch {
            log.error("startCall: CXStartCallAction rejected: \(PrivacyRedactor.error(error))")
        }

        if kind == .video {
            await requestCameraAccessIfNeeded()
        }
        configureAudioSessionForCall()
        guard let pc = await makePeerConnection() else { terminate(fromRemote: false); return }
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
        log.info("startCall: offer ready, sending + triggering push")

        var msg = Relay_Content_CallMessage()
        msg.type = .offer
        msg.callID = callId
        msg.sdp = offer.sdp
        msg.ice = Self.metadataJSON(kind: kind)
        guard await (onSendCallMessage?(msg, peerAccount) ?? false) else {
            failCall("Couldn’t send the call invite.", notifyPeer: false)
            return
        }
        await onTriggerPush?(peerAccount, callId, localDisplayNameProvider?() ?? "Relay", kind)
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

    /// Reports an incoming call to CallKit.
    /// - Parameter pushCompletion: The PushKit push handler completion. When provided it is
    ///   called inside `reportNewIncomingCall`'s callback — this is what Apple requires to
    ///   satisfy the VoIP push contract. Callers from the WS path omit it.
    func reportIncomingCall(
        callId: String,
        callerAccount: String,
        callerName: String,
        kind: CallKind = .audio,
        pushCompletion: (() -> Void)? = nil
    ) {
        // Group calls never use VoIP pushes. If a stale 1:1 VoIP push arrives
        // while the group call UI is active, silently satisfy PushKit and exit.
        if isInGroupCall {
            pushCompletion?()
            return
        }
        // If the WS already registered this exact call (it beat the VoIP push),
        // don't re-report to CallKit and don't send BUSY — just satisfy PushKit.
        if case .incoming(let existingId, _, _) = state, existingId == callId {
            pushCompletion?()
            return
        }
        guard case .idle = state else {
            Task {
                var msg = Relay_Content_CallMessage()
                msg.type = .busy
                msg.callID = callId
                _ = await onSendCallMessage?(msg, callerAccount)
            }
            if let pushCompletion {
                reportAndEndRejectedPushCall(callId: callId, callerName: callerName, completion: pushCompletion)
            } else {
                pushCompletion?()
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
        let foreground = pushCompletion == nil && UIApplication.shared.applicationState == .active
        if foreground {
            startRingtone()
            return
        }

        hasCallKitReport = true
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.hasVideo = kind == .video
        // iOS 18.4.1+ bug: provider(_:didActivate:) is unreliable. Apple's
        // official workaround: call setConfiguration before reportNewIncomingCall
        // to force the audio session to activate correctly.
        provider.configuration = providerConfig
        // Call pushCompletion INSIDE this callback — not before it.
        // Apple terminates apps that fail to call completion quickly,
        // and blacklists them from future VoIP deliveries.
        provider.reportNewIncomingCall(with: uuid, update: update) { [pushCompletion, log] error in
            if let error {
                log.error("report incoming call failed: \(PrivacyRedactor.error(error))")
            }
            pushCompletion?()
        }
    }

    private func reportAndEndRejectedPushCall(callId: String, callerName: String, completion: @escaping () -> Void) {
        let uuid = UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.hasVideo = false
        provider.configuration = providerConfig
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
        guard let pc = await makePeerConnection() else { terminate(fromRemote: false); return }
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
        guard let pc = await makePeerConnection() else { terminate(fromRemote: false); return }
        peerConnection = pc
        addLocalMedia(to: pc, kind: storedCallKind)
        state = .connecting
        if let offer = pendingOffer {
            pendingOffer = nil
            await applyOffer(offer, from: answerPeer)
        }
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
        }
        await handleCallMessage(msg, from: info.callerAccount)
    }

    func handleCallMessage(_ msg: Relay_Content_CallMessage, from account: String) async {
        // Route all group-call signals to the dedicated handler.
        if !msg.groupID.isEmpty || msg.type == .groupRing || msg.type == .groupJoin || msg.type == .groupLeave {
            await handleGroupCallMessage(msg, from: account)
            return
        }
        switch msg.type {
        case .offer:
            let kind = Self.callKind(fromMetadata: msg.ice) ?? (Self.sdpContainsVideo(msg.sdp) ? .video : .audio)
            if case .incoming(let existingId, _, _) = state, existingId == msg.callID {
                // VoIP push already registered this call; store SDP for when user answers.
                storedCallKind = kind
                if storedCallPeer?.isEmpty != false { storedCallPeer = account }
                updateCallKitVideoIfNeeded(kind: kind)
                pendingOffer = msg
            } else if case .connecting = state, peerConnection != nil, storedCallId == msg.callID {
                // callKitAnswered() ran before OFFER arrived; apply directly.
                storedCallKind = kind
                if storedCallPeer?.isEmpty != false { storedCallPeer = account }
                updateCallKitVideoIfNeeded(kind: kind)
                await applyOffer(msg, from: account)
            } else {
                // Fresh incoming call via WS — resolve display name before reporting to CallKit.
                let displayName = nameResolver?(account) ?? account
                reportIncomingCall(callId: msg.callID, callerAccount: account, callerName: displayName, kind: kind)
                pendingOffer = msg
            }

        case .answer:
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
            guard let candidate = parseIce(msg.ice) else { return }
            if let pc = peerConnection, hasRemoteDescription {
                try? await pc.add(candidate)
            } else {
                // Remote description not yet applied — queue for drain after setRemoteDescription.
                pendingRemoteCandidates.append(candidate)
                log.info("ICE candidate queued (no remote description yet); queue=\(self.pendingRemoteCandidates.count)")
            }

        case .hangup:
            terminate(fromRemote: true)

        case .busy:
            terminate(fromRemote: true, outcomeOverride: .declined)

        case .ringing, .groupRing, .groupJoin, .groupLeave, .UNRECOGNIZED:
            break
        }
    }

    private func updateCallKitVideoIfNeeded(kind: CallKind) {
        guard kind == .video, hasCallKitReport, let uuid = activeCallUUID else { return }
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: storedPeerName ?? "Relay")
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
            reply.sdp = answer.sdp
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
        log.error("call failed: \(PrivacyRedactor.redactedString(reason))")
        callTimeoutTask?.cancel()
        callTimeoutTask = nil
        iceRecoveryTask?.cancel()
        iceRecoveryTask = nil
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
        callTimeoutTask?.cancel()
        callTimeoutTask = nil
        iceRecoveryTask?.cancel()
        iceRecoveryTask = nil

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
        content.title = callerName
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

    private func makePeerConnection() async -> RTCPeerConnection? {
        let config = RTCConfiguration()
        let servers = await freshIceServers()
        config.iceServers = servers
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.iceCandidatePoolSize = 4
        if shouldForceRelay(servers) {
            config.iceTransportPolicy = .relay
        }
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
        // Return cached credentials if still valid (with a 60s safety margin).
        if let cached = cachedTurnCredentials, cached.expiresAt > Date().addingTimeInterval(60) {
            return iceServers(from: cached.creds)
        }
        if let fetch = onFetchTurnCredentials {
            do {
                if let creds = try await fetch() {
                    let ttl = TimeInterval(max(creds.ttl, 60))
                    cachedTurnCredentials = (creds, Date().addingTimeInterval(ttl))
                    return iceServers(from: creds)
                }
            } catch {
                log.warning("TURN credential fetch failed, falling back to relay/host candidates: \(PrivacyRedactor.error(error))")
            }
        }
        return Self.staticIceServers()
    }

    private func iceServers(from creds: TurnCredentials) -> [RTCIceServer] {
        let turnURLs = creds.urls.filter { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") }
        let stunURLs = creds.urls.filter { $0.hasPrefix("stun:") }
        var servers: [RTCIceServer] = []
        if !turnURLs.isEmpty {
            servers.append(RTCIceServer(urlStrings: turnURLs, username: creds.username, credential: creds.credential))
        }
        // Include (relay-operated) STUN: when private mode forces `.relay`, WebRTC
        // ignores non-relay candidates anyway; when TURN is absent we DON'T force
        // relay, so STUN is what lets the call connect. It's the relay's own STUN,
        // not a third party, so it doesn't leak your IP to an outside provider.
        if !stunURLs.isEmpty {
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
        let callId = UUID().uuidString
        groupCallId = callId
        groupCallGroupId = groupId
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
        let targets = (info.participants + [info.callerAccount]).filter { $0 != ownAccountId }
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

    private func handleGroupCallMessage(_ msg: Relay_Content_CallMessage, from account: String) async {
        switch msg.type {
        case .groupRing:
            // If a stale VoIP push already pushed us into .incoming for this
            // same callId, tear down the phantom 1:1 call and handle as group.
            if case .incoming(let existingId, _, _) = state, existingId == msg.callID {
                terminate(fromRemote: false, reportToCallKit: true)
            }
            guard !isInGroupCall, case .idle = state else { return }
            let displayName = nameResolver?(account) ?? account
            groupCallId = msg.callID
            groupCallGroupId = msg.groupID
            groupCallKind = Self.callKind(fromMetadata: msg.ice) ?? .audio
            isInGroupCall = true
            groupRingInfo = GroupRingInfo(
                callId: msg.callID, groupId: msg.groupID,
                callerAccount: account, callerName: displayName,
                participants: msg.participants, kind: groupCallKind
            )
            startRingtone()

        case .groupJoin:
            guard isInGroupCall, groupCallId == msg.callID, groupPeers[account] == nil else { return }
            let peerName = nameResolver?(account) ?? account
            groupPeers[account] = GroupCallPeer(peerAccount: account, peerName: peerName)
            await initiateGroupPeerOffer(toPeer: account, callId: msg.callID)

        case .groupLeave:
            guard isInGroupCall, groupCallId == msg.callID else { return }
            closeGroupPeerConnection(forAccount: account)
            groupPeers.removeValue(forKey: account)
            groupPeerDelegates.removeValue(forKey: account)

        case .offer:
            // Mesh OFFER from a group peer — only process if addressed to us.
            guard isInGroupCall, msg.targetAccount == ownAccountId else { return }
            let peerName = nameResolver?(account) ?? account
            if groupPeers[account] == nil {
                groupPeers[account] = GroupCallPeer(peerAccount: account, peerName: peerName)
            }
            await handleGroupPeerOffer(msg, from: account)

        case .answer:
            guard isInGroupCall else { return }
            await handleGroupPeerAnswer(msg, from: account)

        case .ice:
            guard isInGroupCall else { return }
            await handleGroupPeerICE(msg, from: account)

        case .hangup, .busy:
            guard isInGroupCall, groupCallId == msg.callID else { return }
            closeGroupPeerConnection(forAccount: account)
            groupPeers.removeValue(forKey: account)
            groupPeerDelegates.removeValue(forKey: account)
            if groupPeers.isEmpty { endGroupCallCleanup() }

        default:
            break
        }
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
        msg.sdp = offer.sdp
        msg.targetAccount = account
        _ = await onSendCallMessage?(msg, account)
    }

    private func handleGroupPeerOffer(_ msg: Relay_Content_CallMessage, from account: String) async {
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
            reply.sdp = answer.sdp
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
                    // Re-assert enabled in case the audio session was briefly
                    // interrupted between join and first peer connect.
                    RTCAudioSession.sharedInstance().isAudioEnabled = true
                case .failed, .disconnected:
                    self.groupPeers[account]?.isConnected = false
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

        let config = RTCConfiguration()
        let servers = await freshIceServers()
        config.iceServers = servers
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.iceCandidatePoolSize = 4
        if shouldForceRelay(servers) { config.iceTransportPolicy = .relay }
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
        groupCallKind = .audio
        groupCallDisplayName = "Group Call"
        groupRingInfo = nil
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
        Task { @MainActor in
            log.info("ICE candidate gathered type=\(candidateType)")
            // Use stored values — these are set at call start and valid through
            // all state transitions (.outgoing → .connecting → .active).
            guard let peerAccount = storedCallPeer else { return }
            let callId = storedCallId ?? ""
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
            provider.configuration = providerConfig
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
