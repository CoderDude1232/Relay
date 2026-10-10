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
    var onMinimize: (() -> Void)? = nil
    @Environment(CallManager.self) private var callManager
    @State private var elapsed = 0
    @State private var connectedAt: Date?

    private var peers: [GroupCallPeer] {
        callManager.groupPeers.values.sorted { $0.peerName.localizedCaseInsensitiveCompare($1.peerName) == .orderedAscending }
    }

    private var isVideo: Bool { callManager.groupCallKind == .video }

    var body: some View {
        ZStack {
            // One other person: same backdrop as a 1:1 call — their photo as a
            // vivid blur, or their avatar colour.
            // While waiting alone it matches your own photo/avatar colour.
            CallBackdrop(name: backdropName, photo: backdropPhoto,
                         matchAvatar: peers.count <= 1 && callManager.groupRingInfo == nil)

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

    private var myName: String { service.myDisplayName ?? service.username ?? "You" }

    private var backdropName: String {
        guard callManager.groupRingInfo == nil else { return callManager.groupCallDisplayName }
        switch peers.count {
        case 0: return myName
        case 1: return peers[0].peerName
        default: return callManager.groupCallDisplayName
        }
    }

    private var backdropPhoto: Data? {
        guard callManager.groupRingInfo == nil else { return nil }
        switch peers.count {
        case 0: return service.myAvatarData
        case 1: return avatar(peers[0])
        default: return nil
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
                    .padding(.bottom, 50)
            }

            if isVideo, let track = callManager.groupCallLocalVideoTrack {
                SelfPreview(track: track, dimmed: !callManager.isVideoEnabled)
                    .onTapGesture(count: 2) { callManager.flipGroupCamera() }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            if let onMinimize {
                Button(action: onMinimize) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .glassCompat(in: .circle)
                }
                .accessibilityLabel("Minimize call")
            }
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
                    if connectedAt != nil, peers.contains(where: { !$0.isConnected }) {
                        // Someone's connection dropped and is being rebuilt.
                        Image(systemName: "wifi.slash")
                            .symbolEffect(.pulse)
                            .accessibilityLabel("Reconnecting")
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
                AvatarView(name: myName, size: 120,
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
        HStack(spacing: 0) {
            Spacer()
            audioRoundButton(
                icon: callManager.isSpeaker ? "speaker.wave.3.fill" : "speaker.wave.2.fill",
                label: "Speaker",
                background: callManager.isSpeaker ? .white.opacity(0.35) : .white.opacity(0.18),
                foreground: .white
            ) { callManager.toggleSpeaker() }
            Spacer()
            audioRoundButton(
                icon: callManager.isMuted ? "mic.slash.fill" : "mic.fill",
                label: callManager.isMuted ? "Unmute" : "Mute",
                background: callManager.isMuted ? .white.opacity(0.18) : .white,
                foreground: callManager.isMuted ? .white : .black
            ) { callManager.toggleMute() }
            Spacer()
            if isVideo {
                audioRoundButton(
                    icon: callManager.isVideoEnabled ? "video.fill" : "video.slash.fill",
                    label: callManager.isVideoEnabled ? "Camera" : "No Camera",
                    background: callManager.isVideoEnabled ? .white.opacity(0.18) : .white.opacity(0.10),
                    foreground: .white
                ) { callManager.toggleVideo() }
                Spacer()
            }
            audioRoundButton(
                icon: "phone.down.fill",
                label: "Leave",
                background: Color(red: 0.93, green: 0.28, blue: 0.20),
                foreground: .white
            ) { callManager.leaveGroupCall() }
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
    /// One other person: match CallView exactly (photo wash or avatar-colour gradient).
    var matchAvatar = false

    var body: some View {
        ZStack {
            Color.black
            if let photo, let image = DecodedImageCache.image(for: photo) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 80, opaque: true)
                    .saturation(2.2)
                    .brightness(-0.05)
                    .overlay(Color.black.opacity(0.38))
            } else if matchAvatar {
                LinearGradient(
                    stops: [
                        .init(color: color.opacity(0.80), location: 0),
                        .init(color: color.opacity(0.40), location: 0.40),
                        .init(color: color.opacity(0.05), location: 0.80),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            } else {
                RadialGradient(colors: [color.opacity(0.55), .clear],
                               center: UnitPoint(x: 0.5, y: 0.15), startRadius: 0, endRadius: 600)
            }
        }
        .ignoresSafeArea()
    }

    /// Same palette and hash as AvatarView, so it matches the avatar's colour.
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
