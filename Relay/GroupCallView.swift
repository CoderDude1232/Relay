//
//  GroupCallView.swift
//  Relay
//
//  Group calls and call-link calls (full-mesh WebRTC). The layout adapts to
//  who's here: alone → a waiting screen (with Invite for call links), one
//  other person → a 1:1 layout like CallView, two → stacked, more → a grid.
//  Controls sit in one glass bar at the bottom.
//

import RelayCore
import RelayKit
import SwiftUI
import WebRTC

struct GroupCallView: View {
    let service: MessagingService
    @Environment(CallManager.self) private var callManager
    @State private var elapsed = 0
    @State private var connectedAt: Date?

    private var peers: [GroupCallPeer] {
        callManager.groupPeers.values.sorted { $0.peerName.localizedCaseInsensitiveCompare($1.peerName) == .orderedAscending }
    }

    private var isVideo: Bool { callManager.groupCallKind == .video }

    var body: some View {
        ZStack {
            CallBackdrop(name: callManager.groupCallDisplayName,
                         photo: peers.count == 1 ? avatar(peers[0]) : nil)

            if callManager.groupRingInfo != nil {
                incomingLayout
            } else {
                activeLayout
            }
        }
        .statusBar(hidden: true)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if let connectedAt { elapsed = Int(Date().timeIntervalSince(connectedAt)) }
            }
        }
        .onChange(of: peers.contains(where: \.isConnected)) { _, connected in
            if connected, connectedAt == nil {
                connectedAt = Date()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
    }

    private func avatar(_ peer: GroupCallPeer) -> Data? {
        service.peerAvatarData(forAccount: peer.peerAccount)
    }

    private var statusText: String {
        if peers.isEmpty { return callManager.currentLinkCallId != nil ? "Waiting for people to join" : "Calling…" }
        if connectedAt == nil { return "Connecting…" }
        return String(format: "%d:%02d", elapsed / 60, elapsed % 60)
    }

    // MARK: - Incoming

    private var incomingLayout: some View {
        let info = callManager.groupRingInfo
        return VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle().fill(.white.opacity(0.12)).frame(width: 150, height: 150)
                Image(systemName: "person.3.fill")
                    .font(.system(size: 54, weight: .medium))
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
            .padding(.bottom, 28)

            Text(callManager.groupCallDisplayName)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text(callManager.groupCallKind == .video ? "Group video call" : "Group call")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.top, 6)
            if let caller = info?.callerName, !caller.isEmpty {
                Text("Started by \(caller)")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 4)
            }
            Spacer()
            HStack(spacing: 80) {
                bigButton(icon: "phone.down.fill", tint: .red, label: "Decline") {
                    callManager.declineGroupCall()
                }
                bigButton(icon: callManager.groupCallKind == .video ? "video.fill" : "phone.fill",
                          tint: .green, label: "Join") {
                    Task { await callManager.joinGroupCall() }
                }
            }
            .padding(.bottom, 60)
        }
    }

    // MARK: - Active

    private var activeLayout: some View {
        ZStack {
            stage
                .ignoresSafeArea(edges: peers.count == 1 && isVideo ? .all : [])

            VStack(spacing: 0) {
                header
                    .padding(.top, 12)
                    .padding(.horizontal, 16)
                Spacer()
                controlBar
                    .padding(.bottom, 24)
            }

            if isVideo, let track = callManager.groupCallLocalVideoTrack {
                SelfPreview(track: track, dimmed: !callManager.isVideoEnabled)
                    .onTapGesture(count: 2) { callManager.flipGroupCamera() }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(peers.count == 1 ? peers[0].peerName : callManager.groupCallDisplayName)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if peers.count > 1 {
                        Label("\(peers.count + 1)", systemImage: "person.2.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    Text(statusText).monospacedDigit()
                }
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassCompat(in: .rect(cornerRadius: 20))
            Spacer(minLength: 0)
            if callManager.isLinkHost, let id = callManager.currentLinkCallId,
               let link = CallLinkStore.shared.link(id) {
                ShareLink(item: link.url(hostAccount: service.credentials.accountId)) {
                    Label("Invite", systemImage: "person.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .glassCompat(in: .capsule)
                }
            }
        }
    }

    // MARK: - Stage

    @ViewBuilder
    private var stage: some View {
        switch peers.count {
        case 0:
            waiting
        case 1:
            soloPeer(peers[0])
        case 2:
            VStack(spacing: 10) {
                ForEach(peers) { tile($0) }
            }
            .padding(.horizontal, 12)
            .padding(.top, 96)
            .padding(.bottom, 130)
        default:
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(peers) { tile($0).aspectRatio(3 / 4, contentMode: .fit) }
                }
                .padding(.horizontal, 12)
                .padding(.top, 96)
                .padding(.bottom, 140)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var waiting: some View {
        VStack(spacing: 18) {
            ZStack {
                PulseRing()
                AvatarView(name: service.myDisplayName ?? service.username ?? "You", size: 120,
                           imageData: service.myAvatarData)
            }
            Text(callManager.currentLinkCallId != nil ? "You're the first one here" : "Calling…")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            if callManager.isLinkHost {
                Text("Share the link and let people in as they arrive.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
    }

    /// One other person: like a 1:1 call.
    @ViewBuilder
    private func soloPeer(_ peer: GroupCallPeer) -> some View {
        if let track = peer.remoteVideoTrack {
            GroupRTCVideoTrackView(track: track)
                .ignoresSafeArea()
        } else {
            VStack(spacing: 18) {
                AvatarView(name: peer.peerName, size: 160, imageData: avatar(peer))
                    .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
                Text(peer.peerName)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                if !peer.isConnected {
                    Text("Connecting…")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }

    private func tile(_ peer: GroupCallPeer) -> some View {
        ZStack {
            if let track = peer.remoteVideoTrack {
                GroupRTCVideoTrackView(track: track)
            } else {
                Rectangle().fill(.white.opacity(0.08))
                AvatarView(name: peer.peerName, size: 84, imageData: avatar(peer))
            }
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                if !peer.isConnected {
                    ProgressView().controlSize(.mini).tint(.white)
                }
                Text(peer.peerName).lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.35), in: .capsule)
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(.rect(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(peer.isConnected ? 0.12 : 0.05), lineWidth: 1)
        )
    }

    // MARK: - Controls

    private var controlBar: some View {
        HStack(spacing: 14) {
            roundButton(icon: callManager.isSpeaker ? "speaker.wave.3.fill" : "speaker.fill",
                        on: callManager.isSpeaker, label: "Speaker") { callManager.toggleSpeaker() }
            roundButton(icon: callManager.isMuted ? "mic.slash.fill" : "mic.fill",
                        on: callManager.isMuted, label: callManager.isMuted ? "Unmute" : "Mute") { callManager.toggleMute() }
            if isVideo {
                roundButton(icon: callManager.isVideoEnabled ? "video.fill" : "video.slash.fill",
                            on: !callManager.isVideoEnabled, label: "Camera") { callManager.toggleVideo() }
                roundButton(icon: "arrow.triangle.2.circlepath.camera.fill", on: false, label: "Flip camera") {
                    callManager.flipGroupCamera()
                }
            }
            Button { callManager.leaveGroupCall() } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(Color.red, in: .circle)
            }
            .accessibilityLabel("Leave call")
        }
        .padding(10)
        .glassCompat(in: .capsule)
    }

    private func roundButton(icon: String, on: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(on ? Color.black : Color.white)
                .frame(width: 58, height: 58)
                .background(on ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.white.opacity(0.14)), in: .circle)
        }
        .accessibilityLabel(label)
    }

    private func bigButton(icon: String, tint: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .background(tint, in: .circle)
                Text(label).font(.footnote).foregroundStyle(.white.opacity(0.85))
            }
        }
    }
}

// MARK: - Pieces

/// Dark backdrop with a soft wash: the other person's photo when there's one,
/// otherwise a colour from the call name (same palette as avatars).
private struct CallBackdrop: View {
    let name: String
    let photo: Data?

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.03, blue: 0.07)
            if let photo, let image = DecodedImageCache.image(for: photo) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 80, opaque: true)
                    .saturation(1.8)
                    .overlay(Color.black.opacity(0.45))
            } else {
                RadialGradient(colors: [color.opacity(0.55), .clear],
                               center: UnitPoint(x: 0.5, y: 0.15), startRadius: 0, endRadius: 600)
            }
        }
        .ignoresSafeArea()
    }

    private var color: Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green]
        var hash = 0
        for scalar in name.unicodeScalars { hash = (hash &* 31 &+ Int(scalar.value)) }
        return palette[abs(hash) % palette.count]
    }
}

/// Your own camera, floating in the top-right corner. Double-tap to flip.
private struct SelfPreview: View {
    let track: RTCVideoTrack
    let dimmed: Bool

    var body: some View {
        VStack {
            HStack {
                Spacer()
                GroupRTCVideoTrackView(track: track)
                    .frame(width: 104, height: 150)
                    .clipShape(.rect(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 1))
                    .opacity(dimmed ? 0.4 : 1)
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                    .accessibilityLabel("Your camera. Double-tap to flip.")
            }
            Spacer()
        }
        .padding(.top, 84)
        .padding(.trailing, 14)
    }
}

private struct PulseRing: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .stroke(.white.opacity(0.25), lineWidth: 2)
            .frame(width: 150, height: 150)
            .scaleEffect(pulse ? 1.25 : 0.95)
            .opacity(pulse ? 0 : 1)
            .onAppear {
                withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { pulse = true }
            }
    }
}

// MARK: - RTCVideoTrack renderer

struct GroupRTCVideoTrackView: UIViewRepresentable {
    let track: RTCVideoTrack

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFill
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

    class Coordinator {
        var track: RTCVideoTrack?
    }
}
