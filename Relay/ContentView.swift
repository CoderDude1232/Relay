//
//  ContentView.swift
//  Relay
//

import LocalAuthentication
import SecureStorage
import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var isObscured = false
    @State private var isLocked = false
    @State private var backgroundedAt: Date? = nil
    @State private var isAuthenticating = false

    @AppStorage("relay.screenLockEnabled") private var screenLockEnabled = false
    @AppStorage("relay.screenLockTimeout") private var screenLockTimeout = 60

    var body: some View {
        ZStack {
            switch model.phase {
            case .loading:
                ProgressView()
            case .onboarding:
                OnboardingView()
            case .ready(let service):
                MainTabView(service: service)
            case .failed(let message):
                ContentUnavailableView(
                    "Storage Unavailable",
                    systemImage: "lock.trianglebadge.exclamationmark",
                    description: Text(message)
                )
            }

            // Privacy screen: covers content the instant the app loses focus.
            // Uses UIKit notifications rather than scenePhase so it fires
            // synchronously at the start of the swipe, not a frame later.
            if isObscured {
                Rectangle()
                    .fill(.regularMaterial)
                    .ignoresSafeArea()
                    .zIndex(100)
            }

            if isLocked {
                ScreenLockView(isAuthenticating: isAuthenticating) {
                    guard !isAuthenticating else { return }
                    isAuthenticating = true
                    Task {
                        let ok = await BiometricGate.authenticate(reason: "Unlock Relay")
                        isAuthenticating = false
                        if ok { isLocked = false }
                    }
                }
                .ignoresSafeArea()
                .zIndex(101)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            isObscured = true
            if screenLockEnabled { backgroundedAt = Date() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            isObscured = false
            guard screenLockEnabled, !isLocked else { return }
            let elapsed = backgroundedAt.map { Date().timeIntervalSince($0) } ?? .infinity
            if elapsed >= Double(screenLockTimeout) {
                isLocked = true
                Task {
                    // Auto-prompt on resume so the user doesn't need to tap.
                    try? await Task.sleep(for: .milliseconds(200))
                    guard isLocked, !isAuthenticating else { return }
                    isAuthenticating = true
                    let ok = await BiometricGate.authenticate(reason: "Unlock Relay")
                    isAuthenticating = false
                    if ok { isLocked = false }
                }
            }
        }
    }
}

// MARK: - Lock screen

private struct ScreenLockView: View {
    let isAuthenticating: Bool
    let onUnlock: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)

            VStack(spacing: 28) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 52, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)

                Text("Relay is Locked")
                    .font(.title2.weight(.bold))

                Button(action: onUnlock) {
                    HStack(spacing: 8) {
                        if isAuthenticating {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.85)
                        } else {
                            Image(systemName: biometricIcon)
                        }
                        Text(isAuthenticating ? "Authenticating…" : "Unlock")
                    }
                    .font(.headline)
                    .frame(width: 200, height: 50)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(.white)
                }
                .disabled(isAuthenticating)
            }
        }
    }

    private var biometricIcon: String {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            return context.biometryType == .faceID ? "faceid" : "touchid"
        }
        return "lock.open.fill"
    }
}

struct MainTabView: View {
    let service: MessagingService
    @Environment(AppModel.self) private var model
    @Environment(CallManager.self) private var callManager
    @State private var callMinimized = false
    @State private var deepLinkError: String?
    @State private var selectedTab = 0
    @State private var joinGroupError: String?

    private var isCallActive: Bool {
        switch callManager.state {
        case .idle, .ended: return false
        default: return true
        }
    }

    private var callPeerName: String {
        switch callManager.state {
        case .outgoing(_, _, let name): return name
        case .incoming(_, _, let name): return name
        default:
            if let account = callManager.storedPeerAccount {
                return service.displayName(forAccount: account)
            }
            return callManager.storedPeerName ?? "Unknown"
        }
    }

    private var callPeerAccount: String? {
        switch callManager.state {
        case .outgoing(_, let account, _): return account
        case .incoming(_, let account, _): return account
        default: return callManager.storedPeerAccount
        }
    }

    private var totalUnread: Int {
        service.conversations.filter { !$0.archived }.reduce(0) { $0 + $1.unreadCount }
    }

    private var profileName: String {
        service.myDisplayName ?? service.username ?? "?"
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                Tab("Chats", systemImage: "bubble.left.and.bubble.right.fill", value: 0) {
                    ConversationListView(service: service)
                }
                .badge(totalUnread)

                Tab("Calls", systemImage: "phone.fill", value: 1) {
                    CallsView(service: service)
                }
                .badge(service.callHistory.filter { $0.outcome == .missed }.count)

                Tab(value: 2) {
                    SettingsView(service: service)
                } label: {
                    Label {
                        Text("Profile")
                    } icon: {
                        ProfileTabIcon(data: service.myAvatarData, name: profileName)
                    }
                }
            }

            // Floats above the tab bar without moving any content.
            if isCallActive && callMinimized {
                MinimizedCallBar(
                    callManager: callManager,
                    peerName: callPeerName,
                    onReturn: { withAnimation(.spring(duration: 0.3)) { callMinimized = false } }
                )
                .padding(.bottom, 49) // tab bar height
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(1)
            }

            if isCallActive && !callMinimized {
                CallView(
                    callManager: callManager,
                    peerName: callPeerName,
                    peerAvatar: callPeerAccount.flatMap { service.peerAvatarData(forAccount: $0) },
                    onMinimize: { withAnimation(.spring(duration: 0.3)) { callMinimized = true } }
                )
                .transition(.opacity)
                .zIndex(2)
            }

            if callManager.isInGroupCall {
                GroupCallView()
                    .transition(.opacity)
                    .zIndex(3)
            }

            if service.authenticationExpired {
                // Relay credentials were rejected (401). Clear only the relay
                // account so the user can re-register; keep the Supabase session
                // so they don't have to re-enter their password.
                ExpiredSessionView {
                    model.signOutRelayOnly()
                }
                .transition(.opacity)
                .zIndex(3)
            }
        }
        .animation(.spring(duration: 0.3), value: callMinimized)
        .onChange(of: isCallActive) { _, active in
            if active {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
                )
            }
            if !active { callMinimized = false }
        }
        .onChange(of: model.pendingNotificationConversationId) { _, id in
            guard id != nil else { return }
            selectedTab = 0
        }
        .onChange(of: model.pendingDeepLinkUsername) { _, username in
            guard let username else { return }
            model.pendingDeepLinkUsername = nil
            Task {
                do {
                    _ = try await service.startConversation(username: username)
                } catch {
                    deepLinkError = "@\(username) was not found on Relay."
                }
            }
        }
        .onChange(of: model.pendingGroupInviteToken) { _, token in
            guard let token else { return }
            model.pendingGroupInviteToken = nil
            Task {
                do {
                    let conversationId = try await service.joinGroupByInvite(token: token)
                    model.pendingNotificationConversationId = conversationId
                    selectedTab = 0
                } catch {
                    joinGroupError = "Invite link is invalid or has already been used."
                }
            }
        }
        .alert("User Not Found", isPresented: Binding(
            get: { deepLinkError != nil },
            set: { if !$0 { deepLinkError = nil } }
        )) {
            Button("OK", role: .cancel) { deepLinkError = nil }
        } message: {
            Text(deepLinkError ?? "")
        }
        .alert("Invalid Invite", isPresented: Binding(
            get: { joinGroupError != nil },
            set: { if !$0 { joinGroupError = nil } }
        )) {
            Button("OK", role: .cancel) { joinGroupError = nil }
        } message: {
            Text(joinGroupError ?? "")
        }
    }
}

private struct ExpiredSessionView: View {
    let onSignInAgain: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 54, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.orange)

            VStack(spacing: 8) {
                Text("Session Expired")
                    .font(.title2.weight(.bold))
                Text("Your session was revoked or expired — this can happen if you signed in on another device or changed your password. Sign in again to reconnect.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            Button(role: .destructive, action: onSignInAgain) {
                Text("Sign In Again")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: 260)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .ignoresSafeArea()
    }
}

// MARK: - Profile tab icon

// UIGraphicsImageRenderer uses the main screen scale by default, so the
// resulting UIImage has size=(side,side) in points at the correct pixel
// density — no manual scale math, no blur, no oversized frame.
// .withRenderingMode(.alwaysOriginal) prevents the tab bar tinting the photo.
private struct ProfileTabIcon: View {
    let data: Data?
    let name: String

    var body: some View {
        if let data, let src = UIImage(data: data) {
            Image(uiImage: circularCrop(src))
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 24))
        }
    }

    private func circularCrop(_ src: UIImage) -> UIImage {
        let side: CGFloat = 28
        let sz = CGSize(width: side, height: side)
        // Renderer auto-uses UIScreen.main.scale → sharp pixels, correct pt size.
        let cropped = UIGraphicsImageRenderer(size: sz).image { _ in
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: sz)).addClip()
            let s = src.size
            let ratio = max(side / s.width, side / s.height)
            src.draw(in: CGRect(
                x: (side - s.width * ratio) / 2,
                y: (side - s.height * ratio) / 2,
                width: s.width * ratio,
                height: s.height * ratio
            ))
        }
        return cropped.withRenderingMode(.alwaysOriginal)
    }
}

// MARK: - Minimized call bar

private struct MinimizedCallBar: View {
    let callManager: CallManager
    let peerName: String
    let onReturn: () -> Void

    @State private var elapsed = 0

    private var statusText: String {
        switch callManager.state {
        case .outgoing:
            "Ringing..."
        case .connecting:
            "Connecting audio..."
        case .active(_, let start):
            formatCallDuration(Date().timeIntervalSince(start))
        default:
            "Call in progress"
        }
    }

    var body: some View {
        Button(action: onReturn) {
            HStack(spacing: 12) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 1) {
                    Text(peerName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(statusText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    callManager.endActiveCall()
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.red, in: .circle)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .glassCompat(in: .capsule)
            .overlay {
                Capsule()
                    .strokeBorder(.green.opacity(0.4), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if case .active(_, let start) = callManager.state {
                    elapsed = Int(Date().timeIntervalSince(start))
                }
            }
        }
    }
}

func formatCallDuration(_ s: Double) -> String {
    let t = Int(s)
    return String(format: "%d:%02d", t / 60, t % 60)
}
