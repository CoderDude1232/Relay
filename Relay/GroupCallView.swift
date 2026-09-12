//
//  GroupCallView.swift
//  Relay
//
//  Full-mesh P2P group call UI. Mirrors CallView's visual language:
//  same gradient background, same audioRoundButton controls, same callButton
//  for incoming ring, participant tiles with avatar/video fallback.
//

import SwiftUI
import WebRTC

struct GroupCallView: View {
    @Environment(CallManager.self) private var callManager
    @State private var elapsed = 0

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

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
                elapsed += 1
            }
        }
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            Color.black
            let c = nameColor(callManager.groupCallDisplayName)
            LinearGradient(
                stops: [
                    .init(color: c.opacity(0.72), location: 0),
                    .init(color: c.opacity(0.32), location: 0.45),
                    .init(color: c.opacity(0.05), location: 0.85),
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    private func nameColor(_ name: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green]
        var hash = 0
        for scalar in name.unicodeScalars { hash = (hash &* 31 &+ Int(scalar.value)) }
        return palette[abs(hash) % palette.count]
    }

    // MARK: - Incoming ring layout

    private var incomingLayout: some View {
        let info = callManager.groupRingInfo
        return VStack(spacing: 0) {
            Spacer()

            Image(systemName: "person.3.fill")
                .font(.system(size: 76, weight: .light))
                .foregroundStyle(.white.opacity(0.88))
                .shadow(color: .black.opacity(0.28), radius: 28)
                .padding(.bottom, 36)

            Text(callManager.groupCallDisplayName)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)

            Text("Incoming group call")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.65))
                .padding(.top, 8)

            if let caller = info?.callerName, !caller.isEmpty {
                Text("Started by \(caller)")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.48))
                    .padding(.top, 4)
            }

            Spacer()

            HStack(spacing: 72) {
                callButton(
                    icon: "phone.down.fill",
                    color: Color(red: 0.93, green: 0.28, blue: 0.20),
                    label: "Decline"
                ) {
                    callManager.declineGroupCall()
                }
                callButton(
                    icon: "phone.fill",
                    color: Color(red: 0.21, green: 0.78, blue: 0.35),
                    label: "Join"
                ) {
                    Task { await callManager.joinGroupCall() }
                }
            }

            Spacer().frame(height: 64)
        }
    }

    // MARK: - Active call layout

    private var activeLayout: some View {
        VStack(spacing: 0) {
            callHeader
                .padding(.top, 16)
                .padding(.horizontal, 20)

            ZStack(alignment: .topTrailing) {
                participantArea
                    .padding(.top, 12)

                if callManager.groupCallKind == .video,
                   let track = callManager.groupCallLocalVideoTrack {
                    localPip(track: track)
                        .padding(.top, 62)
                        .padding(.trailing, 16)
                }
            }

            Spacer(minLength: 16)
            activeControls
            Spacer().frame(height: 50)
        }
    }

    private var callHeader: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Text(callManager.groupCallDisplayName)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                HStack(spacing: 5) {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.58))
                    Text("\(callManager.groupPeers.count + 1) participants")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.65))
                    if callManager.groupPeers.values.contains(where: { $0.isConnected }) {
                        Text("·")
                            .foregroundStyle(.white.opacity(0.38))
                        Text(formattedElapsed)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.65))
                            .monospacedDigit()
                    }
                }
            }
            Spacer()
        }
    }

    private var formattedElapsed: String {
        String(format: "%d:%02d", elapsed / 60, elapsed % 60)
    }

    // MARK: - Participant grid

    @ViewBuilder
    private var participantArea: some View {
        let peers = Array(callManager.groupPeers.values)
        if peers.isEmpty {
            waitingView
        } else {
            let cols = peers.count == 1 ? 1 : 2
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: cols),
                spacing: 8
            ) {
                ForEach(peers) { peer in
                    GroupParticipantTile(peer: peer, nameColorFn: nameColor)
                        .aspectRatio(3 / 4, contentMode: .fit)
                }
            }
            .padding(.horizontal, 8)
        }
    }

    private var waitingView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "person.2.wave.2")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.32))
            Text("Waiting for others to join…")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.48))
            Spacer()
        }
    }

    private func localPip(track: RTCVideoTrack) -> some View {
        GroupRTCVideoTrackView(track: track)
            .frame(width: 118, height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.28), lineWidth: 1)
            )
            .opacity(callManager.isVideoEnabled ? 1 : 0.45)
            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
    }

    // MARK: - Controls (identical style to CallView.activeControls)

    private var activeControls: some View {
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
            if callManager.groupCallKind == .video {
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

    // MARK: - Button helpers (mirrors CallView exactly)

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

// MARK: - Participant tile

private struct GroupParticipantTile: View {
    let peer: GroupCallPeer
    let nameColorFn: (String) -> Color

    var body: some View {
        ZStack(alignment: .bottom) {
            // Video or colored avatar fill
            if let track = peer.remoteVideoTrack {
                GroupRTCVideoTrackView(track: track)
            } else {
                nameColorFn(peer.peerName).opacity(0.55)
                Text(String(peer.peerName.prefix(1)).uppercased())
                    .font(.system(size: 52, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
            }

            // Name bar
            HStack(spacing: 6) {
                if !peer.isConnected {
                    ProgressView()
                        .scaleEffect(0.65)
                        .tint(.white)
                }
                Text(peer.peerName)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.black.opacity(0.42))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
