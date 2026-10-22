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
                    .fullScreenCover(isPresented: Binding(get: { model.removedFromAccount }, set: { _ in })) {
                        RemovedFromAccountView()
                    }
                    .task(id: model.shouldOfferPasskey) {
                        guard model.shouldOfferPasskey else { return }
                        try? await Task.sleep(for: .seconds(3))
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

        }
        .alert(
            "Join @\(model.linkConfirmation?.username ?? "")?",
            isPresented: Binding(get: { model.linkConfirmation != nil }, set: { _ in }),
            presenting: model.linkConfirmation
        ) { confirmation in
            Button("Join") { confirmation.respond(true) }
            Button("Cancel", role: .cancel) { confirmation.respond(false) }
        } message: { confirmation in
            Text("Link code \(confirmation.code). Only join if this is your username and your other device shows the same code.")
        }
        // The privacy blur and the lock screen live in their own window above
        // everything (see PrivacyShield): a sheet or full-screen photo is
        // presented above any overlay in this hierarchy.
        .onAppear { updateShield() }
        .onChange(of: isObscured) { updateShield() }
        .onChange(of: isLocked) { updateShield() }
        .onChange(of: isAuthenticating) { updateShield() }
        .task {
            // Cold launch with the app lock on: prompt right away.
            guard isLocked, !isAuthenticating else { return }
            isAuthenticating = true
            let ok = await BiometricGate.authenticate(reason: "Unlock Relay")
            isAuthenticating = false
            if ok { isLocked = false }
        }
        // A shared proxy link goes through the same check and trust warning.
        .sheet(isPresented: Binding(
            get: { model.pendingProxy != nil }, set: { if !$0 { model.pendingProxy = nil } }
        )) {
            NavigationStack {
                ProxySettingsView(initialAddress: model.pendingProxy)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { model.pendingProxy = nil }
                        }
                    }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            isObscured = true
            // Synchronously: the app-switcher snapshot is taken right after this.
            updateShield()
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

// MARK: - Removed from the account

/// Shown when the relay reports that this device is no longer on the account.
/// Nothing is deleted until the user says so.
private struct RemovedFromAccountView: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Signed Out on This iPhone")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            Text("Your account was signed in on another device, or this one was removed from it. Relay has stopped here. Your messages are still on this iPhone until you delete them.\n\nIf this wasn't you, sign in again right away and check your passkeys, recovery key and account password.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(role: .destructive) {
                confirming = true
            } label: {
                Text("Sign Out and Delete Data").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(28)
        .confirmationDialog("Delete Relay's data on this iPhone?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Delete Data and Sign Out", role: .destructive) {
                model.signOut(removeFromServer: false)
            }
        } message: {
            Text("Messages that aren't in your encrypted message history backup can't be recovered afterwards.")
        }
        .interactiveDismissDisabled()
    }
}

// MARK: - Lock screen

extension ContentView {
    private func updateShield() {
        PrivacyShield.shared.update(
            obscured: isObscured, locked: isLocked, authenticating: isAuthenticating
        ) { [self] in
            guard !isAuthenticating else { return }
            isAuthenticating = true
            Task {
                let ok = await BiometricGate.authenticate(reason: "Unlock Relay")
                isAuthenticating = false
                if ok { isLocked = false }
            }
        }
    }
}

/// A window above the app's own (sheets and full-screen covers included) that
/// shows the app-switcher blur or the lock screen.
@MainActor
final class PrivacyShield {
    static let shared = PrivacyShield()

    @Observable
    final class State {
        var obscured = false
        var locked = false
        var authenticating = false
        var onUnlock: () -> Void = {}
    }

    private let state = State()
    private var window: UIWindow?
    private weak var shieldLogo: UIImageView?

    func update(obscured: Bool, locked: Bool, authenticating: Bool, onUnlock: @escaping () -> Void) {
        state.obscured = obscured
        state.locked = locked
        state.authenticating = authenticating
        state.onUnlock = onUnlock
        guard obscured || locked else {
            window?.isHidden = true
            return
        }
        if locked {
            // Don't leave a half-typed message showing in the keyboard.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        if window == nil {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                ?? scenes.first(where: { $0.activationState == .foregroundInactive })
                ?? scenes.first
            else { return }
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            let host = UIHostingController(rootView: ShieldView(state: state))
            host.view.backgroundColor = .clear
            host.view.accessibilityViewIsModal = true
            window.rootViewController = host
            self.window = window
        }
        // A heavy blur put in place through UIKit, so it's there in the very
        // next frame: the app-switcher snapshot can be taken before SwiftUI
        // renders. Strong enough that photos and text aren't readable.
        if let root = window?.rootViewController?.view, !(root.subviews.first is UIVisualEffectView) {
            let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
            blur.frame = root.bounds
            blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            let dim = UIView(frame: blur.bounds)
            dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            dim.backgroundColor = UIColor.black.withAlphaComponent(0.35)
            blur.contentView.addSubview(dim)
            // The logo is added here too (not only in SwiftUI) so it's in
            // the snapshot.
            let logo = UIImageView(image: UIImage(named: "RelayLogo"))
            logo.contentMode = .scaleAspectFit
            logo.translatesAutoresizingMaskIntoConstraints = false
            blur.contentView.addSubview(logo)
            NSLayoutConstraint.activate([
                logo.centerXAnchor.constraint(equalTo: blur.contentView.centerXAnchor),
                logo.centerYAnchor.constraint(equalTo: blur.contentView.centerYAnchor),
                logo.widthAnchor.constraint(equalToConstant: 170),
            ])
            shieldLogo = logo
            root.insertSubview(blur, at: 0)
        }
        // The lock screen draws its own logo, with the unlock button.
        shieldLogo?.isHidden = locked
        window?.isHidden = false
    }

    private struct ShieldView: View {
        let state: State

        var body: some View {
            ZStack {
                if state.locked {
                    ScreenLockView(isAuthenticating: state.authenticating, onUnlock: state.onUnlock)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .environment(\.colorScheme, .dark)
        }
    }
}

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
                Text("Messages on this device will be deleted. Messages in your encrypted backup come back when you sign in again.")
            }
        }
    }
}

private struct ScreenLockView: View {
    let isAuthenticating: Bool
    let onUnlock: () -> Void

    var body: some View {
        ZStack {
            // The shield window's blur sits behind this.
            VStack(spacing: 28) {
                Image("RelayLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 170)
                    .accessibilityLabel("Relay")

                Label("Locked", systemImage: "lock.fill")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.75))

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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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

    /// Room left under a minimized call bar for the tab bar (none beside the rail).
    private var tabBarInset: CGFloat { horizontalSizeClass == .regular ? 12 : 49 }

    /// iPhone: the standard tab bar. iPad (and other wide windows): each
    /// tab is a split view and the tabs float at the foot of its list
    /// column, so chats get the full height. All three stay alive so
    /// switching keeps each one's place.
    @ViewBuilder
    private var tabs: some View {
        if horizontalSizeClass == .regular {
            ZStack {
                ConversationListView(service: service)
                    .railPage(selectedTab == 0)
                CallsView(service: service)
                    .railPage(selectedTab == 1)
                SettingsView(service: service)
                    .railPage(selectedTab == 2)
            }
            .background { tabShortcuts }
            .environment(\.sidebarTabs, SidebarTabs(
                selection: $selectedTab,
                chatsBadge: totalUnread,
                callsBadge: unseenMissedCalls,
                avatarData: service.myAvatarData,
                profileName: profileName
            ))
        } else {
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
        }
    }

    private var inAppBannerLayer: some View {
        ZStack {
        if let banner = service.inAppBanner {
            VStack {
                InAppBannerView(banner: banner) {
                    service.inAppBanner = nil
                    selectedTab = 0
                    model.pendingNotificationConversationId = banner.conversationId
                } onDismiss: {
                    if service.inAppBanner?.id == banner.id { service.inAppBanner = nil }
                }
                .padding(.top, 6)
                .frame(maxWidth: 520)
                Spacer()
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .zIndex(5)
            .id(banner.id)
        }
        }
        .animation(.spring(duration: 0.35, bounce: 0.2), value: service.inAppBanner?.id)
    }

    /// ⌘1–⌘3 switch tabs from a hardware keyboard.
    private var tabShortcuts: some View {
        Group {
            Button("Chats") { selectedTab = 0 }.keyboardShortcut("1", modifiers: .command)
            Button("Calls") { selectedTab = 1 }.keyboardShortcut("2", modifiers: .command)
            Button("Profile") { selectedTab = 2 }.keyboardShortcut("3", modifiers: .command)
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            tabs

            // Floats above the tab bar without moving any content.
            if isCallActive && callMinimized {
                MinimizedCallBar(
                    callManager: callManager,
                    peerName: callPeerName,
                    onReturn: { withAnimation(.spring(duration: 0.3)) { callMinimized = false } }
                )
                .padding(.bottom, tabBarInset)
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
                .padding(.bottom, tabBarInset)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(1)
            }

            inAppBannerLayer

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
private extension View {
    /// One of the iPad tabs: kept alive, shown only when selected.
    func railPage(_ selected: Bool) -> some View {
        opacity(selected ? 1 : 0)
            .allowsHitTesting(selected)
            .accessibilityHidden(!selected)
    }
}

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

/// A glass banner at the top for a message in another chat. Tap opens the
/// chat; swipe up (or wait) dismisses it.
private struct InAppBannerView: View {
    let banner: MessagingService.InAppBanner
    let onOpen: () -> Void
    let onDismiss: () -> Void
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: banner.avatarName, size: 38, imageData: banner.avatarData)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(banner.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .glassCompat(in: .rect(cornerRadius: 22))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 12)
        .offset(y: min(0, dragOffset))
        .contentShape(.rect)
        .onTapGesture(perform: onOpen)
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { dragOffset = $0.translation.height }
                .onEnded { value in
                    if value.translation.height < -24 { onDismiss() } else {
                        withAnimation(.spring(duration: 0.25)) { dragOffset = 0 }
                    }
                }
        )
        .task {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            try? await Task.sleep(for: .seconds(4))
            onDismiss()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the chat")
        .accessibilityAction(named: "Dismiss", onDismiss)
    }
}
