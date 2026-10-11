//
//  ContentView.swift
//  Relay
//

import LocalAuthentication
import RelayCore
import RelayKit
import SecureStorage
import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var isObscured = false
    // Start locked on a cold launch so a launching link or notification can't
    // land before unlock.
    @State private var isLocked = UserDefaults.standard.bool(forKey: "relay.screenLockEnabled")
    @State private var backgroundedAt: Date? = nil
    @State private var isAuthenticating = false
    @State private var foundBackup: CloudBackupManager.FoundBackup?
    @State private var showingPasskeyOffer = false
    @State private var passkeyError: String?

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
                    .environment(\.relayAppLocked, isLocked)
                    .task(id: model.shouldOfferBackupRestore) {
                        guard model.shouldOfferBackupRestore else { return }
                        model.shouldOfferBackupRestore = false
                        // No backup: the account starts without history.
                        foundBackup = await CloudBackupManager.shared
                            .findBackupAfterSignIn(accountId: service.credentials.accountId)
                    }
                    .alert("Restore Your Messages?", isPresented: Binding(
                        get: { foundBackup != nil },
                        set: { if !$0 { foundBackup = nil } }
                    ), presenting: foundBackup) { found in
                        Button("Restore") {
                            CloudBackupManager.shared.restore(found, into: service)
                        }
                        Button("Start Fresh", role: .cancel) {}
                    } message: { found in
                        Text("An iCloud backup from \(found.updatedAt.formatted(date: .abbreviated, time: .shortened)) was found for this account.")
                    }
                    .task(id: model.shouldOfferPasskey) {
                        guard model.shouldOfferPasskey else { return }
                        // After the iCloud restore offer, which is looked up first.
                        try? await Task.sleep(for: .seconds(3))
                        while foundBackup != nil { try? await Task.sleep(for: .milliseconds(500)) }
                        showingPasskeyOffer = model.shouldOfferPasskey
                    }
                    .alert("Sign In Faster Next Time?", isPresented: $showingPasskeyOffer) {
                        Button("Create Passkey") {
                            Task {
                                do { try await model.createPasskey() } catch PasskeyError.canceled {
                                } catch { passkeyError = FriendlyError.message(for: error) }
                            }
                        }
                        Button("Not Now", role: .cancel) {
                            model.shouldOfferPasskey = false
                            UserDefaults.standard.set(true, forKey: AppModel.passkeyPromptDismissedKey)
                        }
                    } message: {
                        Text("A passkey signs you in with Face ID on a new iPhone, and brings your chat list back — no password or email code needed.")
                    }
                    .sheet(isPresented: Binding(
                        get: { model.newRecoveryKey != nil }, set: { if !$0 { model.newRecoveryKey = nil } }
                    )) {
                        if let key = model.newRecoveryKey {
                            NewRecoveryKeySheet(key: key) { model.newRecoveryKey = nil }
                        }
                    }
                    .alert("Couldn't Create Passkey", isPresented: Binding(
                        get: { passkeyError != nil }, set: { if !$0 { passkeyError = nil } }
                    )) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text(passkeyError ?? "")
                    }
            case .failed(let message):
                StorageUnavailableView(message: message)
            }

            // Privacy screen. UIKit notifications fire synchronously at the start
            // of the app-switcher swipe; scenePhase arrives a frame later.
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
        .task {
            // Cold launch with the app lock on: prompt right away.
            guard isLocked, !isAuthenticating else { return }
            isAuthenticating = true
            let ok = await BiometricGate.authenticate(reason: "Unlock Relay")
            isAuthenticating = false
            if ok { isLocked = false }
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

/// Shown when the encrypted database can't be opened at launch. Offers a
/// retry (usually protected data isn't available yet) and a local reset.
private struct StorageUnavailableView: View {
    let message: String
    @Environment(AppModel.self) private var model
    @State private var isRetrying = false
    @State private var confirmingReset = false

    var body: some View {
        ContentUnavailableView {
            Label("Storage Unavailable", systemImage: "lock.trianglebadge.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button {
                isRetrying = true
                Task {
                    await model.retryBoot()
                    isRetrying = false
                }
            } label: {
                if isRetrying { ProgressView() } else { Text("Try Again") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRetrying)

            Button("Sign Out & Reset", role: .destructive) {
                confirmingReset = true
            }
            .disabled(isRetrying)
            .confirmationDialog(
                "Sign out and reset Relay on this device?",
                isPresented: $confirmingReset,
                titleVisibility: .visible
            ) {
                Button("Sign Out & Reset", role: .destructive) {
                    // Storage is broken, so there's no session to deregister.
                    model.signOut(removeFromServer: false)
                }
            } message: {
                Text("Messages on this device will be deleted. You can restore them only from an iCloud backup or another linked device.")
            }
        }
    }
}

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
    @State private var groupCallMinimized = false
    @State private var deepLinkError: String?
    @State private var selectedTab = 0
    @State private var joinGroupError: String?
    @State private var inviteError: String?
    @State private var pendingLinkAction: PendingLinkAction?
    @Environment(\.relayAppLocked) private var appLocked
    /// Missed calls at or before this time (ms since epoch) have been seen and
    /// don't count toward the Calls tab badge.
    @AppStorage(CallsView.missedCallsSeenAtKey) private var missedCallsSeenAt: Double = 0

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

    private var unseenMissedCalls: Int {
        service.callHistory.filter {
            $0.outcome == .missed && Double($0.startedAt) > missedCallsSeenAt
        }.count
    }

    private func markMissedCallsSeen() {
        let newest = service.callHistory.map { Double($0.startedAt) }.max() ?? 0
        missedCallsSeenAt = max(missedCallsSeenAt, newest, Date().timeIntervalSince1970 * 1000)
    }

    /// Asks the user to confirm a pending username, contact or group invite
    /// link. Nothing happens without confirmation, and links wait while locked.
    private func handlePendingLinks() {
        guard !appLocked, pendingLinkAction == nil else { return }
        if let username = model.pendingDeepLinkUsername {
            model.pendingDeepLinkUsername = nil
            pendingLinkAction = .username(username)
            return
        }
        if let token = model.pendingContactInviteToken {
            model.pendingContactInviteToken = nil
            pendingLinkAction = .contactInvite(token: token)
            return
        }
        if let link = model.pendingCallLink {
            model.pendingCallLink = nil
            if link.host == service.credentials.accountId {
                // Our own link: start it instead of asking ourselves.
                if let record = CallLinkStore.shared.link(link.callId) {
                    Task { await callManager.startLinkCall(callId: record.id, name: record.name) }
                }
            } else {
                pendingLinkAction = .callLink(callId: link.callId, host: link.host, secret: link.secret)
            }
            return
        }
        if let raw = model.pendingGroupInviteToken {
            model.pendingGroupInviteToken = nil
            let parts = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let token = String(parts[0])
            let fragment = parts.count > 1 ? String(parts[1]) : ""
            Task {
                do {
                    // Decrypts the invite to show its name and size; doesn't join.
                    let preview = try await service.previewGroupInvite(token: token, fragment: fragment)
                    if let conversationId = preview.existingConversationId {
                        // Already a member: just open it.
                        selectedTab = 0
                        model.pendingNotificationConversationId = conversationId
                    } else {
                        pendingLinkAction = .groupInvite(preview)
                    }
                } catch {
                    joinGroupError = "Invite link is invalid or has already been used."
                }
            }
        }
    }

    /// Runs a link action the user just confirmed.
    private func performConfirmedLink(_ action: PendingLinkAction) {
        Task {
            switch action {
            case .username(let username):
                do {
                    let conversationId = try await service.startConversation(username: username)
                    selectedTab = 0
                    model.pendingNotificationConversationId = conversationId
                } catch {
                    deepLinkError = "@\(username) was not found on Relay."
                }
            case .contactInvite(let token):
                do {
                    let username = try await service.claimContactInvite(token: token)
                    let conversationId = try await service.startConversation(username: username)
                    selectedTab = 0
                    model.pendingNotificationConversationId = conversationId
                } catch {
                    inviteError = "This invite link is invalid or has already been used."
                }
            case .callLink(let callId, let host, let secret):
                await callManager.requestToJoinLink(callId: callId, hostAccount: host, secret: secret)
            case .groupInvite(let preview):
                do {
                    let conversationId = try await service.acceptGroupInvite(preview)
                    selectedTab = 0
                    model.pendingNotificationConversationId = conversationId
                } catch {
                    joinGroupError = "Couldn’t join this group. The invite may have expired."
                }
            }
            // Another link may have queued up behind this one.
            handlePendingLinks()
        }
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
                .badge(unseenMissedCalls)

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

            if callManager.isInGroupCall && !groupCallMinimized {
                GroupCallView(service: service, onMinimize: callManager.groupRingInfo == nil ? {
                    withAnimation(.spring(duration: 0.3)) { groupCallMinimized = true }
                } : nil)
                .transition(.opacity)
                .zIndex(3)
            }
            if callManager.isInGroupCall && groupCallMinimized {
                MinimizedCallBar(
                    callManager: callManager,
                    peerName: callManager.groupPeers.count == 1
                        ? (callManager.groupPeers.values.first?.peerName ?? callManager.groupCallDisplayName)
                        : callManager.groupCallDisplayName,
                    onReturn: { withAnimation(.spring(duration: 0.3)) { groupCallMinimized = false } },
                    status: callManager.groupPeers.isEmpty ? "Waiting for others"
                        : "\(callManager.groupPeers.count + 1) in call",
                    onEnd: { callManager.leaveGroupCall() }
                )
                .padding(.bottom, 49)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(1)
            }

            // Call links: host admit prompts, and the joiner's waiting card.
            if let request = callManager.linkJoinRequests.first {
                VStack {
                    LinkJoinRequestBanner(request: request)
                        .padding(.top, 8)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(4)
            }
            if let join = callManager.outgoingLinkJoin {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    OutgoingLinkJoinCard(join: join)
                }
                .transition(.opacity)
                .zIndex(4)
            }

            if service.authenticationExpired {
                // 401: clear only the relay account so the user can re-register,
                // keeping the Supabase session so no password is needed.
                ExpiredSessionView {
                    model.signOutRelayOnly()
                }
                .transition(.opacity)
                .zIndex(3)
            }
        }
        .animation(.spring(duration: 0.3), value: callMinimized)
        .onChange(of: callManager.isInGroupCall) { _, inCall in
            if !inCall { groupCallMinimized = false }
        }
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
        .onChange(of: model.pendingScanQR) { _, requested in
            if requested { selectedTab = 0 }
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == 1 { markMissedCallsSeen() }
        }
        .onChange(of: service.callHistory.count) { _, _ in
            // A call logged while the Calls tab is on screen is seen immediately.
            if selectedTab == 1 { markMissedCallsSeen() }
        }
        .onChange(of: model.pendingDeepLinkUsername) { _, _ in handlePendingLinks() }
        .onChange(of: model.pendingContactInviteToken) { _, _ in handlePendingLinks() }
        .onChange(of: model.pendingGroupInviteToken) { _, _ in handlePendingLinks() }
        .onChange(of: model.pendingCallLink?.callId) { _, _ in handlePendingLinks() }
        .animation(.spring(duration: 0.3), value: callManager.linkJoinRequests)
        .animation(.spring(duration: 0.3), value: callManager.outgoingLinkJoin)
        // Links that arrived while the app lock was up run once it's unlocked.
        .onChange(of: appLocked) { _, locked in if !locked { handlePendingLinks() } }
        // Links from a cold start or onboarding were set before this view
        // existed, so onChange never saw them.
        .onAppear { handlePendingLinks() }
        .sheet(item: $pendingLinkAction) { action in
            LinkConfirmationSheet(
                action: action,
                onConfirm: {
                    pendingLinkAction = nil
                    performConfirmedLink(action)
                },
                onCancel: {
                    pendingLinkAction = nil
                    Task { @MainActor in handlePendingLinks() }
                }
            )
        }
        .alert("User Not Found", isPresented: Binding(
            get: { deepLinkError != nil },
            set: { if !$0 { deepLinkError = nil } }
        )) {
            Button("OK", role: .cancel) { deepLinkError = nil }
        } message: {
            Text(deepLinkError ?? "")
        }
        .alert("Invite Link Not Valid", isPresented: Binding(
            get: { inviteError != nil },
            set: { if !$0 { inviteError = nil } }
        )) {
            Button("OK", role: .cancel) { inviteError = nil }
        } message: {
            Text(inviteError ?? "")
        }
        .alert("Invalid Invite", isPresented: Binding(
            get: { joinGroupError != nil },
            set: { if !$0 { joinGroupError = nil } }
        )) {
            Button("OK", role: .cancel) { joinGroupError = nil }
        } message: {
            Text(joinGroupError ?? "")
        }
        .alert("Call Not Started", isPresented: Binding(
            get: { callManager.groupCallFailureMessage != nil },
            set: { if !$0 { callManager.groupCallFailureMessage = nil } }
        )) {
            Button("OK", role: .cancel) { callManager.groupCallFailureMessage = nil }
        } message: {
            Text(callManager.groupCallFailureMessage ?? "")
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

// .alwaysOriginal stops the tab bar from tinting the photo.
private struct ProfileTabIcon: View {
    let data: Data?
    let name: String

    var body: some View {
        if let data, let src = DecodedImageCache.image(for: data) {
            Image(uiImage: circularCrop(src))
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 24))
        }
    }

    private func circularCrop(_ src: UIImage) -> UIImage {
        let side: CGFloat = 28
        let sz = CGSize(width: side, height: side)
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
    /// Group and call-link calls supply their own status and hang-up.
    var status: String? = nil
    var onEnd: (() -> Void)? = nil

    @State private var elapsed = 0

    private var statusText: String {
        switch callManager.state {
        case .outgoing:
            "Ringing\u{2026}"
        case .connecting:
            "Connecting audio\u{2026}"
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
                    Text(status ?? statusText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    if let onEnd { onEnd() } else { callManager.endActiveCall() }
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.red, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("End call")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .glassCompat(in: .capsule)
            .overlay {
                Capsule()
                    .strokeBorder(.green.opacity(0.4), lineWidth: 1)
            }
            // One element: VoiceOver can't reach a button nested in a button.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Call with \(peerName), \(status ?? statusText)")
            .accessibilityHint("Returns to the call")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "End call") {
                if let onEnd { onEnd() } else { callManager.endActiveCall() }
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
