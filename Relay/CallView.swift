//
//  CallView.swift
//  Relay
//
//  In-app call UI for outgoing, active and foreground incoming calls.
//  Background incoming calls use CallKit's lock-screen UI.
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
    @State private var audioRoute = CallAudioRoute()
    /// Pull-down distance while swiping the call away.
    @State private var dismissDrag: CGFloat = 0

    var body: some View {
        ZStack {
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
        .simultaneousGesture(TapGesture().onEnded { revealControls() })
        // Swipe down to minimize, like closing a sheet.
        .offset(y: dismissDrag)
        .scaleEffect(1 - min(dismissDrag, 300) / 3000, anchor: .top)
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onChanged { value in
                    guard onMinimize != nil, value.translation.height > 0,
                          abs(value.translation.height) > abs(value.translation.width) else { return }
                    dismissDrag = value.translation.height
                }
                .onEnded { value in
                    guard onMinimize != nil else { return }
                    if value.translation.height > 140 || value.predictedEndTranslation.height > 320 {
                        onMinimize?()
                        dismissDrag = 0
                    } else {
                        withAnimation(.spring(duration: 0.3)) { dismissDrag = 0 }
                    }
                }
        )
        .task {
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if case .active(_, let start) = callManager.state {
                    elapsed = Int(Date().timeIntervalSince(start))
                    tick += 1
                    if tick % 3 == 0 { await callManager.refreshCallQuality() }
                }
            }
        }
        .onAppear { revealControls() }
        .onDisappear { controlsHideTask?.cancel() }
        .onChange(of: callManager.isReconnecting) { _, reconnecting in
            AccessibilityNotification.Announcement(reconnecting ? "Reconnecting" : "Reconnected").post()
        }
        .onChange(of: callManager.state) { old, new in
            revealControls()
            announce(from: old, to: new)
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
        // Dark base so the screen isn't blank while layers load.
        Color.black.ignoresSafeArea()

        if let data = peerAvatar, let uiImage = DecodedImageCache.image(for: data) {
            // In an overlay so the filled photo can't widen the screen: a bare
            // scaledToFill image sizes the whole ZStack to the photo, which
            // pushed the Speaker and End buttons off the sides.
            Color.clear
                .overlay {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 80, opaque: true)
                        .saturation(2.2)
                        .brightness(-0.05)
                }
                .clipped()
                .overlay(Color.black.opacity(0.38))
                .ignoresSafeArea()
        } else {
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

    // Must match AvatarView.avatarColor.
    private func peerNameColor(_ name: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green]
        var hash = 0
        for scalar in name.unicodeScalars { hash = (hash &* 31 &+ Int(scalar.value)) }
        return palette[Int(hash.magnitude % UInt(palette.count))]
    }

    // Controls only auto-hide during active video calls.
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
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
            HStack(spacing: 6) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.60))
                    .accessibilityHidden(true)
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
                qualityIndicator
            }
            if callManager.callQuality == .poor, !callManager.isReconnecting {
                Text("Poor connection")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.75), in: .capsule)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: callManager.callQuality)
        .accessibilityElement(children: .combine)
    }

    /// Signal bars for the connection, once the call is up.
    @ViewBuilder
    private var qualityIndicator: some View {
        if case .active = callManager.state, callManager.callQuality != .unknown {
            let (value, color, label): (Double, Color, String) = switch callManager.callQuality {
            case .good: (1, .white.opacity(0.75), "Good connection")
            case .fair: (0.66, .yellow, "Fair connection")
            case .poor: (0.33, .orange, "Poor connection")
            case .unknown: (0, .clear, "")
            }
            Image(systemName: "cellularbars", variableValue: value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .accessibilityLabel(label)
        }
    }

    private var videoHeader: some View {
        HStack(alignment: .center) {
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
                    qualityIndicator
                }
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .accessibilityElement(children: .combine)

            Spacer()

            // Balances the minimize button so the name stays centered.
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 8)
        .shadow(radius: 8)
    }

    // MARK: - Video stage

    private var videoStage: some View {
        ZStack(alignment: .topTrailing) {
            // Blurred fill behind an aspect-fit feed: camera video looks
            // full-bleed and screen shares aren't cropped.
            if let remoteTrack = callManager.remoteVideoTrack {
                ZStack {
                    RTCVideoTrackView(track: remoteTrack, contentMode: .scaleAspectFill)
                        .blur(radius: 24, opaque: true)
                        .ignoresSafeArea()
                    RTCVideoTrackView(track: remoteTrack, contentMode: .scaleAspectFit)
                        .ignoresSafeArea()
                }
                .accessibilityElement()
                .accessibilityLabel("\(peerName)'s video")
                .accessibilityAddTraits(.isImage)
            } else {
                Color.black.ignoresSafeArea()
                AvatarView(name: peerName, size: 112, imageData: peerAvatar)
                    .shadow(radius: 20)
            }

            // Local camera, just below the Dynamic Island.
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
                    .accessibilityElement()
                    .accessibilityLabel(callManager.isVideoEnabled ? "Your camera" : "Your camera, off")
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
            .accessibilityAction(named: cameraOptionsExpanded ? "Hide camera options" : "Show camera options") {
                cameraOptionsExpanded.toggle()
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

    /// Spoken by VoiceOver when the call's state changes.
    private func announce(from old: CallState, to new: CallState) {
        let message: String? = switch new {
        case .active: if case .active = old { nil } else { "Call connected" }
        case .failed(let reason): reason
        case .connecting: "Connecting"
        default: nil
        }
        if let message { AccessibilityNotification.Announcement(message).post() }
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

    // MARK: - Incoming controls

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

    // MARK: - Active controls

    private var activeControls: some View {
        HStack(spacing: 0) {
            Spacer()
            if audioRoute.hasExternalRoute {
                // AirPods, Bluetooth or headphones: the system route menu.
                audioRoundButton(
                    icon: audioRoute.icon,
                    label: audioRoute.name,
                    background: Color.white.opacity(0.18),
                    foreground: .white,
                    accessibilityName: "Audio output, \(audioRoute.name)"
                ) {}
                .overlay(alignment: .top) {
                    RoutePickerButton()
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)
                }
            } else {
                audioRoundButton(
                    icon: callManager.isSpeaker ? "speaker.wave.3.fill" : "speaker.wave.2.fill",
                    label: "Speaker",
                    background: callManager.isSpeaker ? Color.white.opacity(0.35) : Color.white.opacity(0.18),
                    foreground: .white,
                    isOn: callManager.isSpeaker
                ) { callManager.toggleSpeaker() }
            }
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
                foreground: .white,
                accessibilityName: "End call"
            ) { callManager.endActiveCall() }
            Spacer()
        }
    }

    private func audioRoundButton(
        icon: String,
        label: String,
        background: Color,
        foreground: Color,
        accessibilityName: String? = nil,
        isOn: Bool? = nil,
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
        .accessibilityLabel(accessibilityName ?? label)
        .accessibilityValue(isOn.map { $0 ? "On" : "Off" } ?? "")
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

/// The current audio output and whether there's anything besides the phone
/// itself (AirPods, Bluetooth, headphones, CarPlay) to choose from.
@Observable
final class CallAudioRoute {
    private(set) var hasExternalRoute = false
    private(set) var name = "Audio"
    private(set) var icon = "speaker.wave.2.fill"
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        update()
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func update() {
        let session = AVAudioSession.sharedInstance()
        let external: Set<AVAudioSession.Port> = [
            .bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .headphones, .headsetMic, .carAudio, .usbAudio,
        ]
        let inputs = session.availableInputs?.map(\.portType) ?? []
        let output = session.currentRoute.outputs.first
        hasExternalRoute = inputs.contains(where: external.contains)
            || session.currentRoute.outputs.contains { external.contains($0.portType) }
        switch output?.portType {
        case .bluetoothHFP?, .bluetoothA2DP?, .bluetoothLE?:
            let product = output?.portName ?? "Bluetooth"
            name = product.localizedCaseInsensitiveContains("airpods") ? "AirPods" : "Bluetooth"
            icon = name == "AirPods" ? "airpods" : "headphones"
        case .headphones?, .headsetMic?:
            name = "Headphones"; icon = "headphones"
        case .carAudio?:
            name = "CarPlay"; icon = "car.fill"
        case .builtInSpeaker?:
            name = "Speaker"; icon = "speaker.wave.3.fill"
        default:
            name = "iPhone"; icon = "iphone"
        }
    }
}

/// The system's audio route menu, invisible over our own button.
private struct RoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(frame: .zero)
        view.activeTintColor = .clear
        view.tintColor = .clear
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

                // RPSystemBroadcastPickerView only shows the system picker on a
                // real user tap. Our broadcast extension is preselected.
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
