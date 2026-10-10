//
//  CallView.swift
//  Relay
//
//  In-app call UI: shown when a call is outgoing or active. Incoming calls
//  that arrive while the app is in the background are handled by CallKit's
//  native lock-screen UI; this view handles in-foreground incoming calls too.
//

import AVKit
import ReplayKit
import SwiftUI
import UIKit
import WebRTC

struct CallView: View {
    let callManager: CallManager
    let peerName: String
    let peerAvatar: Data?
    var onMinimize: (() -> Void)? = nil

    @State private var elapsed = 0
    @State private var cameraOptionsExpanded = false
    @State private var showingDiagnostics = false
    @State private var showingScreenShareOptions = false
    // Controls auto-hide after 4 seconds during active video calls.
    @State private var controlsVisible = true
    @State private var controlsHideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            // Background — purple gradient for audio, dark navy for video
            if isVideoCall {
                LinearGradient(
                    stops: [
                        .init(color: Color(red: 0.06, green: 0.10, blue: 0.22), location: 0),
                        .init(color: Color(red: 0.03, green: 0.05, blue: 0.12), location: 0.6),
                        .init(color: Color(red: 0.01, green: 0.02, blue: 0.06), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()
            } else {
                audioBackground
            }

            if isVideoCall {
                videoStage
            }

            // Controls overlay — fades out during active video calls until tapped.
            VStack(spacing: 0) {
                if isVideoCall {
                    videoHeader
                        .padding(.top, 24)
                    Spacer()
                } else {
                    HStack {
                        if onMinimize != nil {
                            Button { onMinimize?() } label: {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("Minimize call")
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    Spacer()
                    audioIdentity
                    Spacer()
                    Spacer()
                }

                switch callManager.state {
                case .incoming:
                    incomingControls
                case .failed:
                    failedControls
                default:
                    activeControls
                }

                Spacer().frame(height: 50)
            }
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(controlsVisible)
            .animation(.easeInOut(duration: 0.3), value: controlsVisible)
        }
        // Any tap anywhere on screen shows controls and resets the hide timer.
        .simultaneousGesture(TapGesture().onEnded { revealControls() })
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if case .active(_, let start) = callManager.state {
                    elapsed = Int(Date().timeIntervalSince(start))
                }
            }
        }
        .onAppear { revealControls() }
        .onDisappear { controlsHideTask?.cancel() }
        .onChange(of: callManager.state) { old, new in
            revealControls()
            if case .active = new, case .active = old {} else if case .active = new {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
        .sheet(isPresented: $showingDiagnostics) {
            CallDiagnosticsView(callManager: callManager)
        }
        .sheet(isPresented: $showingScreenShareOptions) {
            ScreenShareOptionsView()
        }
    }

    private var isVideoCall: Bool {
        callManager.currentCallKind == .video
    }

    @ViewBuilder
    private var audioBackground: some View {
        // Dark base ensures the screen is never blank while layers load.
        Color.black.ignoresSafeArea()

        if let data = peerAvatar, let uiImage = DecodedImageCache.image(for: data) {
            // Real profile photo — blur heavily and boost saturation to a vivid wash.
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .blur(radius: 80, opaque: true)
                .saturation(2.2)
                .brightness(-0.05)
                .overlay(Color.black.opacity(0.38))
                .ignoresSafeArea()
        } else {
            // No photo — derive gradient from the same color AvatarView picks.
            let color = peerNameColor(peerName)
            LinearGradient(
                stops: [
                    .init(color: color.opacity(0.80), location: 0),
                    .init(color: color.opacity(0.40), location: 0.40),
                    .init(color: color.opacity(0.05), location: 0.80),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    // Mirror of AvatarView.avatarColor so the call background always matches the avatar.
    private func peerNameColor(_ name: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green]
        var hash = 0
        for scalar in name.unicodeScalars { hash = (hash &* 31 &+ Int(scalar.value)) }
        return palette[abs(hash) % palette.count]
    }

    // Show controls immediately and (re)start the 4-second auto-hide timer.
    // During audio calls or non-active states, controls stay permanently visible.
    private func revealControls() {
        controlsHideTask?.cancel()
        if !controlsVisible {
            withAnimation(.easeInOut(duration: 0.25)) { controlsVisible = true }
        } else {
            controlsVisible = true
        }
        guard isVideoCall, case .active = callManager.state else { return }
        controlsHideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.4)) { controlsVisible = false }
            }
        }
    }

    // MARK: - Identity / header

    private var audioIdentity: some View {
        VStack(spacing: 20) {
            AvatarView(name: peerName, size: 160, imageData: peerAvatar)
                .shadow(color: .black.opacity(0.45), radius: 32, y: 12)
            Text(peerName)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
            HStack(spacing: 6) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.60))
                HStack(spacing: 6) {
                    if callManager.isReconnecting {
                        Image(systemName: "wifi.slash")
                            .symbolEffect(.pulse)
                            .accessibilityLabel("Reconnecting")
                    }
                    Text(statusLabel)
                }
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
    }

    private var videoHeader: some View {
        HStack(alignment: .center) {
            // Minimize — left side
            Button { onMinimize?() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.25), in: .circle)
            }
            .accessibilityLabel("Minimize call")
            .accessibilityHidden(onMinimize == nil)
            .opacity(onMinimize != nil ? 1 : 0)

            Spacer()

            // Name + status — centered
            VStack(spacing: 6) {
                Text(peerName)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                HStack(spacing: 6) {
                    if callManager.isReconnecting {
                        Image(systemName: "wifi.slash")
                            .symbolEffect(.pulse)
                            .accessibilityLabel("Reconnecting")
                    }
                    Text(statusLabel)
                }
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
            }

            Spacer()

            // Balance the left button so name stays centered
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 8)
        .shadow(radius: 8)
    }

    // MARK: - Video stage

    private var videoStage: some View {
        ZStack(alignment: .topTrailing) {
            // Remote feed fills the entire screen edge-to-edge.
            // Blurred fill behind an aspect-fit overlay: face calls look full-bleed,
            // screen shares show the complete screen without cropping.
            if let remoteTrack = callManager.remoteVideoTrack {
                ZStack {
                    RTCVideoTrackView(track: remoteTrack, contentMode: .scaleAspectFill)
                        .blur(radius: 24, opaque: true)
                        .ignoresSafeArea()
                    RTCVideoTrackView(track: remoteTrack, contentMode: .scaleAspectFit)
                        .ignoresSafeArea()
                }
            } else {
                Color.black.ignoresSafeArea()
                AvatarView(name: peerName, size: 112, imageData: peerAvatar)
                    .shadow(radius: 20)
            }

            // Local camera — below Dynamic Island with a small breathing gap.
            if let localTrack = callManager.localVideoTrack {
                localCameraPreview(track: localTrack)
                    .padding(.top, 52)
                    .padding(.trailing, 16)
            }
        }
    }

    private func localCameraPreview(track: RTCVideoTrack) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                RTCVideoTrackView(track: track)
                    .frame(width: cameraOptionsExpanded ? 150 : 118, height: cameraOptionsExpanded ? 214 : 170)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.white.opacity(0.28), lineWidth: 1)
                    )
                    .opacity(callManager.isVideoEnabled ? 1 : 0.45)

                if callManager.isScreenSharing {
                    Text("Flip unavailable\nduring screen share")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(8)
                } else {
                    Button {
                        callManager.flipCamera()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .foregroundStyle(.white)
                            .glassCompat(in: .circle)
                    }
                    .accessibilityLabel("Flip camera")
                    .padding(8)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(duration: 0.24)) {
                    cameraOptionsExpanded.toggle()
                }
            }

            if cameraOptionsExpanded {
                HStack(spacing: 8) {
                    Button {
                        callManager.toggleVideo()
                    } label: {
                        Label(
                            callManager.isVideoEnabled ? "Camera On" : "Camera Off",
                            systemImage: callManager.isVideoEnabled ? "video.fill" : "video.slash.fill"
                        )
                        .labelStyle(.iconOnly)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                    }
                    .glassStyleCompat()

                    Button {
                        if callManager.isScreenSharing {
                            callManager.stopSharingScreen()
                        } else {
                            callManager.useDeviceBroadcastScreenShare()
                            showingScreenShareOptions = true
                        }
                    } label: {
                        Label(
                            callManager.isScreenSharing ? "Stop Share" : "Share Screen",
                            systemImage: callManager.isScreenSharing ? "rectangle.slash" : "rectangle.on.rectangle"
                        )
                        .labelStyle(.iconOnly)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                    }
                    .glassStyleCompat()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var statusLabel: String {
        switch callManager.state {
        case .outgoing: return "Ringing…"
        case .connecting: return "Connecting audio…"
        case .incoming: return "Incoming call"
        case .active: return formatCallDuration(Double(elapsed))
        case .failed(let reason): return reason
        default: return ""
        }
    }

    // MARK: - Incoming controls (Answer / Decline)

    private var incomingControls: some View {
        HStack(spacing: 80) {
            callButton(icon: "phone.down.fill", color: .red, label: "Decline") {
                callManager.endActiveCall()
            }
            callButton(icon: "phone.fill", color: .green, label: "Answer") {
                Task { await callManager.answerCall() }
            }
        }
    }

    // MARK: - Failed controls

    private var failedControls: some View {
        callButton(icon: "xmark", color: .gray, label: "Close") {
            callManager.endActiveCall()
        }
    }

    // MARK: - Active controls (Mute / Speaker / End)

    private var activeControls: some View {
        HStack(spacing: 0) {
            Spacer()
            audioRoundButton(
                icon: callManager.isSpeaker ? "speaker.wave.3.fill" : "speaker.wave.2.fill",
                label: "Speaker",
                background: callManager.isSpeaker ? Color.white.opacity(0.35) : Color.white.opacity(0.18),
                foreground: .white
            ) { callManager.toggleSpeaker() }
            Spacer()
            audioRoundButton(
                icon: callManager.isMuted ? "mic.slash.fill" : "mic.fill",
                label: callManager.isMuted ? "Unmute" : "Mute",
                background: callManager.isMuted ? Color.white.opacity(0.18) : Color.white,
                foreground: callManager.isMuted ? .white : .black
            ) { callManager.toggleMute() }
            Spacer()
            audioRoundButton(
                icon: "phone.down.fill",
                label: "End",
                background: Color(red: 0.93, green: 0.28, blue: 0.20),
                foreground: .white
            ) { callManager.endActiveCall() }
            Spacer()
        }
    }

    private func audioRoundButton(
        icon: String,
        label: String,
        background: Color,
        foreground: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .semibold))
                    .frame(width: 72, height: 72)
                    .background(background, in: .circle)
                    .foregroundStyle(foreground)
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .frame(width: 80)
        }
    }

    // MARK: - Button helpers

    private func callButton(icon: String, color: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .semibold))
                    .frame(width: 76, height: 76)
                    .background(color, in: .circle)
                    .foregroundStyle(.white)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.82))
            }
        }
    }

}

private struct RoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(frame: .zero)
        view.activeTintColor = .white
        view.tintColor = .white
        view.prioritizesVideoDevices = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

private struct CallDiagnosticsView: View {
    let callManager: CallManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    diagnosticRow("State", callStateLabel)
                    diagnosticRow("ICE", callManager.diagnostics.iceConnectionState)
                    diagnosticRow("Gathering", callManager.diagnostics.iceGatheringState)
                    diagnosticRow("Signaling", callManager.diagnostics.signalingState)
                }
                Section("Media") {
                    diagnosticRow("Call Type", callManager.currentCallKind.rawValue.capitalized)
                    diagnosticRow("Local Video", callManager.diagnostics.localVideoActive ? "On" : "Off")
                    diagnosticRow("Remote Video", callManager.diagnostics.remoteVideoActive ? "Present" : "Waiting")
                    diagnosticRow("Screen Share", callManager.diagnostics.screenSharingActive ? "On" : "Off")
                    diagnosticRow("Muted", callManager.isMuted ? "Yes" : "No")
                }
                Section("Updated") {
                    Text(callManager.diagnostics.lastUpdated.formatted(date: .omitted, time: .standard))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Call Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var callStateLabel: String {
        switch callManager.state {
        case .idle: "Idle"
        case .outgoing: "Outgoing"
        case .incoming: "Incoming"
        case .connecting: "Connecting"
        case .active: "Active"
        case .failed(let reason): reason
        case .ended: "Ended"
        }
    }

    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ScreenShareOptionsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Tap the button below to start broadcasting your entire screen, including content from other apps.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                // RPSystemBroadcastPickerView — must be tapped by the user to show
                // the system picker. Relay's broadcast extension is pre-selected.
                SystemBroadcastPickerButton()
                    .frame(width: 60, height: 60)

                Spacer()
            }
            .padding(.top, 28)
            .navigationTitle("Share Screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(240)])
    }
}

private struct SystemBroadcastPickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        // Frame must be non-zero or the tap target is unreliable.
        let view = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        view.preferredExtension = "app.relaymsg.RelayBroadcastUpload"
        view.showsMicrophoneButton = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: RPSystemBroadcastPickerView, context: Context) {}
}

private struct RTCVideoTrackView: UIViewRepresentable {
    let track: RTCVideoTrack
    var contentMode: UIView.ContentMode = .scaleAspectFill

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = contentMode
        return view
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        if context.coordinator.track !== track {
            context.coordinator.track?.remove(view)
            track.add(view)
            context.coordinator.track = track
        }
    }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.track?.remove(view)
        coordinator.track = nil
    }

    final class Coordinator {
        var track: RTCVideoTrack?
    }
}
