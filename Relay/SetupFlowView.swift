//
//  SetupFlowView.swift
//  Relay
//
//  A few pages after a new account is made, in the sign-in style, shown in
//  place of the chat list until they're done: how Relay looks, notifications,
//  privacy, and finding people to talk to.
//  Every choice is one Settings also has, and each page can be skipped.
//

import SwiftUI
import UIKit

struct SetupFlowView: View {
    let service: MessagingService
    let onFinish: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(ChatAppearance.self) private var environmentAppearance
    private var app: ChatAppearance { ChatAppearance.app ?? environmentAppearance }

    private enum Page: Hashable { case recovery, look, notifications, privacy, people, done }

    /// Decided once: a new account with a recovery key starts on it.
    @State private var showsRecovery: Bool?
    @State private var index = 0
    @State private var forward = true
    @State private var keySaved = false

    private var pages: [Page] {
        let withKey = showsRecovery ?? (model.recoveryKeyPending || model.newRecoveryKey != nil)
        return (withKey ? [.recovery] : []) + [.look, .notifications, .privacy, .people, .done]
    }
    private var page: Page { pages[min(index, pages.count - 1)] }

    /// Continue waits on the key page until the key has been saved, or
    /// couldn't be made (Settings can make one later).
    private var canContinue: Bool {
        guard page == .recovery else { return true }
        if model.recoveryKeyPending { return false }
        return model.newRecoveryKey == nil || keySaved
    }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                topBar
                ScrollView {
                    Group {
                        switch page {
                        case .recovery: SetupRecoveryKeyPage(saved: $keySaved)
                        case .look: SetupLookPage()
                        case .notifications: SetupNotificationsPage()
                        case .privacy: SetupPrivacyPage(service: service)
                        case .people: SetupPeoplePage(service: service)
                        case .done: SetupDonePage(onFinish: onFinish)
                        }
                    }
                    .id(page)
                    .transition(.asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 480)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                if page != .done {
                    OnboardingPrimaryButton(title: "Continue", enabled: canContinue) {
                        if page == .recovery { model.newRecoveryKey = nil }
                        go(+1)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                    .frame(maxWidth: 480)
                }
            }
        }
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
        .animation(.spring(duration: 0.45), value: index)
        .onAppear {
            if showsRecovery == nil { showsRecovery = model.recoveryKeyPending || model.newRecoveryKey != nil }
        }
    }

    /// The chosen chat wallpaper behind every page once there is one, dimmed
    /// so the white text stays readable; Relay's glow until then.
    @ViewBuilder private var background: some View {
        ZStack {
            BackgroundGradient()
            if let gradient = app.wallpaper.gradient {
                gradient
                    .overlay(Color.black.opacity(0.25))
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: app.wallpaper)
    }

    private var topBar: some View {
        HStack {
            if index > 0 {
                Button { go(-1) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: .circle)
                }
                .accessibilityLabel("Back")
            } else {
                Color.clear.frame(width: 40, height: 40)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(Array(pages.enumerated()), id: \.offset) { i, _ in
                    Capsule()
                        .fill(.white.opacity(i == index ? 0.9 : 0.25))
                        .frame(width: i == index ? 18 : 6, height: 6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \(index + 1) of \(pages.count)")
            Spacer()
            // The key page can't be skipped: it's shown only once.
            Button("Skip") { onFinish() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(minWidth: 40, minHeight: 40)
                .opacity(page == .done || page == .recovery ? 0 : 1)
                .disabled(page == .done || page == .recovery)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .frame(maxWidth: 480)
    }

    private func go(_ step: Int) {
        let next = index + step
        guard pages.indices.contains(next) else { return }
        // No way back to the key once it's been put away.
        if step < 0, pages[next] == .recovery { return }
        forward = step > 0
        index = next
    }
}

// MARK: - Recovery key

private struct SetupRecoveryKeyPage: View {
    @Binding var saved: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 14) {
                Image(systemName: "key.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .background(
                        LinearGradient(colors: [.orange, Color(red: 0.95, green: 0.35, blue: 0.2)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: .rect(cornerRadius: 20, style: .continuous))
                    .shadow(color: .orange.opacity(0.35), radius: 18, y: 6)
                    .accessibilityHidden(true)
                Text("Your Recovery Key")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                Text("If you ever lose your devices, this gets you back in. Keep it somewhere safe.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 8)

            if let key = model.newRecoveryKey {
                VStack(spacing: 14) {
                    Text(RecoveryKeyCard.lines(key))
                        .font(.title3.monospaced().weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 22)
                        .background(.ultraThinMaterial, in: .rect(cornerRadius: 18, style: .continuous))
                        .accessibilityLabel(RecoveryKey.format(key).map { String($0) }.joined(separator: " "))
                    RecoveryKeyCopyButton(key: key)
                }

                Button { saved.toggle() } label: {
                    HStack(spacing: 12) {
                        Image(systemName: saved ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(saved ? .green : .white.opacity(0.5))
                        Text("I've saved it somewhere safe")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.white)
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .contentShape(.rect)
                    .onboardingCard()
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(saved ? .isSelected : [])

                Text("You can see it again in Settings → Account.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.45))
            } else if model.recoveryKeyPending {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Text("Couldn't make your recovery key just now. You can make one in Settings → Account.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(16)
                    .onboardingCard()
            }
        }
    }
}

// MARK: - Look

private struct SetupLookPage: View {
    @Environment(ChatAppearance.self) private var environmentAppearance
    private var app: ChatAppearance { ChatAppearance.app ?? environmentAppearance }

    var body: some View {
        VStack(spacing: 18) {
            OnboardingHeader(title: "Make It Yours", subtitle: "Pick the colours for your chats. You can change them any time in Settings.")

            preview

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ThemeCard(theme: Self.relayTheme, isSelected: isSelected(Self.relayTheme)) {
                        apply(Self.relayTheme)
                    }
                    ForEach(ChatAppearance.themes) { theme in
                        ThemeCard(theme: theme, isSelected: isSelected(theme)) { apply(theme) }
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 1)
            }
            .scrollClipDisabled()
        }
    }

    /// A few messages in the chosen theme, so a tap shows what it does.
    private var preview: some View {
        ZStack {
            if let gradient = app.wallpaper.gradient { gradient } else { Color(white: 0.08) }
            VStack(spacing: 8) {
                bubble("Hey! Are you on Relay now? 👋", outgoing: false)
                bubble("Just joined. Picking my colours 🎨", outgoing: true)
                bubble("Love it", outgoing: false)
            }
            .padding(16)
        }
        .frame(height: 176)
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .animation(.spring(duration: 0.35), value: app.wallpaper)
        .animation(.spring(duration: 0.35), value: app.bubbleTintHex)
        .accessibilityHidden(true)
    }

    private func bubble(_ text: String, outgoing: Bool) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(outgoing ? app.bubbleTint : Color(white: 0.2), in: .rect(cornerRadius: 17, style: .continuous))
            .frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
    }

    /// No wallpaper, Relay's own colour.
    static let relayTheme = AppearanceTheme(id: "relay", name: "Relay", wallpaper: .none, bubbleKey: nil)

    private func isSelected(_ theme: AppearanceTheme) -> Bool {
        app.wallpaper == theme.wallpaper && app.bubbleTintHex == theme.bubbleKey
    }

    private func apply(_ theme: AppearanceTheme) {
        withAnimation(.spring(duration: 0.3)) { app.applyTheme(theme) }
    }
}

// MARK: - Notifications

private struct SetupNotificationsPage: View {
    private var permission = NotificationPermission.shared
    @State private var preview = NotificationPreviewSetting.current

    var body: some View {
        VStack(spacing: 22) {
            OnboardingHeader(title: "Notifications", subtitle: "Choose what your Lock Screen shows when a message arrives.")

            HStack(spacing: 10) {
                ForEach(NotificationPreviewSetting.allCases, id: \.self) { level in
                    LockScreenPreviewCard(level: level, isSelected: preview == level) {
                        preview = level
                        NotificationPreviewSetting.set(level)
                    }
                }
            }

            if permission.isOff {
                Button {
                    NotificationPermission.shared.turnOn(using: AppDelegate.current)
                } label: {
                    Label(permission.status == .denied ? "Turn On in Settings" : "Allow Notifications",
                          systemImage: "bell.badge.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.white.opacity(0.14), in: .capsule)
                        .overlay { Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1) }
                }
                .buttonStyle(.plain)
            } else {
                Label("Notifications are on", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
            }
        }
        .onAppear { permission.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            permission.refresh()
        }
    }
}

// MARK: - Privacy

private struct SetupPrivacyPage: View {
    let service: MessagingService
    @AppStorage(PrivacyPreferences.sendTypingKey) private var sendTyping = true
    @AppStorage(PrivacyPreferences.linkPreviewsKey) private var linkPreviews = true
    @AppStorage(AppSwitcherPrivacy.modeKey) private var appSwitcherMode = AppSwitcherPrivacy.Mode.content.rawValue
    @AppStorage("relay.screenLockEnabled") private var appLock = false
    @State private var readReceipts = true
    @Environment(ChatAppearance.self) private var environmentAppearance
    private var app: ChatAppearance { ChatAppearance.app ?? environmentAppearance }

    var body: some View {
        VStack(spacing: 18) {
            OnboardingHeader(title: "Privacy", subtitle: "Only you and the people you talk to can read your messages. Choose what else they see.")

            preview

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    PrivacyTile(title: "Read Receipts", symbol: "checkmark.message.fill", tint: app.bubbleTint,
                                isOn: Binding(get: { readReceipts },
                                              set: { readReceipts = $0; service.sendReadReceipts = $0 }))
                    PrivacyTile(title: "Typing", symbol: "ellipsis.message.fill", tint: app.bubbleTint, isOn: $sendTyping)
                }
                HStack(spacing: 10) {
                    PrivacyTile(title: "Link Previews", symbol: "link", tint: app.bubbleTint, isOn: $linkPreviews)
                    PrivacyTile(title: "App Lock", symbol: "faceid", tint: app.bubbleTint, isOn: $appLock)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                label("Hide When Switching Apps")
                Picker("Hide When Switching Apps", selection: $appSwitcherMode) {
                    ForEach(AppSwitcherPrivacy.Mode.allCases, id: \.self) { mode in
                        Text(mode == .content ? "Chats" : mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .onAppear { readReceipts = service.sendReadReceipts }
    }

    /// What the people you talk to see, changing as the tiles do.
    private var preview: some View {
        ZStack {
            if let gradient = app.wallpaper.gradient { gradient } else { Color(white: 0.08) }
            VStack(alignment: .trailing, spacing: 6) {
                VStack(alignment: .leading, spacing: 0) {
                    if linkPreviews {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(.white.opacity(0.25))
                                .frame(width: 34, height: 34)
                                .overlay { Image(systemName: "photo").font(.caption).foregroundStyle(.white.opacity(0.8)) }
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Weekend plans").font(.caption.weight(.semibold))
                                Text("example.com").font(.caption2).opacity(0.7)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .background(.black.opacity(0.15))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    Text("Have a look at this 👀")
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .foregroundStyle(.white)
                .frame(width: 200, alignment: .leading)
                .background(app.bubbleTint, in: .rect(cornerRadius: 17, style: .continuous))
                .clipShape(.rect(cornerRadius: 17, style: .continuous))

                Text(readReceipts ? "Read 9:41" : "Delivered")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .contentTransition(.opacity)

                HStack {
                    if sendTyping {
                        HStack(spacing: 4) {
                            ForEach(0..<3) { _ in Circle().fill(.white.opacity(0.7)).frame(width: 6, height: 6) }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .background(Color(white: 0.2), in: .capsule)
                        .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
                    }
                    Spacer()
                }
                .frame(height: 30)
            }
            .padding(16)
        }
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .animation(.spring(duration: 0.35), value: linkPreviews)
        .animation(.spring(duration: 0.35), value: sendTyping)
        .animation(.spring(duration: 0.35), value: readReceipts)
        .accessibilityHidden(true)
    }
}

/// A square on/off tile: tap anywhere on it.
private struct PrivacyTile: View {
    let title: String
    let symbol: String
    let tint: Color
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isOn ? .white : .white.opacity(0.6))
                        .frame(width: 34, height: 34)
                        .background(isOn ? tint : .white.opacity(0.1), in: .circle)
                    Spacer()
                    Text(isOn ? "On" : "Off")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isOn ? .white : .white.opacity(0.5))
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(isOn ? tint.opacity(0.8) : .white.opacity(0.08), lineWidth: isOn ? 1.5 : 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
        .animation(.spring(duration: 0.25), value: isOn)
    }
}

// MARK: - People

private struct SetupPeoplePage: View {
    let service: MessagingService

    private enum ContactsState { case idle, checking, denied, failed(String), found([ContactMatch]) }

    @State private var contacts = ContactsState.idle
    @State private var showingConsent = false
    @State private var starting: String?
    @State private var showingImport = false
    @State private var showingInvite = false

    @Environment(ChatAppearance.self) private var environmentAppearance
    private var tint: Color { (ChatAppearance.app ?? environmentAppearance).bubbleTint }

    var body: some View {
        VStack(spacing: 18) {
            hero
            OnboardingHeader(title: "Find Your People", subtitle: subtitle)

            contactsCard

            // Same height side by side, whichever title wraps.
            HStack(spacing: 10) {
                tile("Import from WhatsApp", symbol: "square.and.arrow.down.on.square.fill",
                     colour: Color(red: 0.15, green: 0.75, blue: 0.4)) { showingImport = true }
                tile("Invite Friends", symbol: "paperplane.fill", colour: tint) { showingInvite = true }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .alert("Find Contacts on Relay?", isPresented: $showingConsent) {
            Button("Find Contacts") {
                ContactDiscoveryConsent.grant()
                check()
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text(ContactDiscoveryConsent.summary)
        }
        .sheet(isPresented: $showingImport) {
            WhatsAppImportView(service: service)
        }
        .sheet(isPresented: $showingInvite) {
            InviteShareSheet(username: service.username)
                .ignoresSafeArea()
        }
    }

    private var subtitle: String {
        if case .found(let matches) = contacts {
            switch matches.count {
            case 0: return "None of your contacts are on Relay yet. Invite them, or bring your chats over."
            case 1: return "1 of your contacts is already on Relay."
            default: return "\(matches.count) of your contacts are already on Relay."
            }
        }
        return "See who's already here, bring your chats over, and invite everyone else."
    }

    @ViewBuilder private var contactsCard: some View {
        switch contacts {
        case .idle:
            action("Find Contacts on Relay", detail: "See which of your contacts already use Relay.", icon: "person.crop.circle.badge.checkmark") {
                ContactDiscoveryConsent.isGranted ? check() : (showingConsent = true)
            }
            .onboardingCard()
        case .checking:
            HStack(spacing: 12) {
                ProgressView().tint(.white)
                Text("Checking your contacts…").foregroundStyle(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .onboardingCard()
        case .denied:
            action("Allow Contacts in Settings", detail: "Turn on Contacts for Relay to see who's here.", icon: "gear") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .onboardingCard()
        case .failed(let message):
            action("Try Again", detail: message, icon: "arrow.clockwise") { check() }
                .onboardingCard()
        case .found(let matches):
            if !matches.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                        if index > 0 { divider }
                        contactRow(match)
                    }
                }
                .onboardingCard()
            }
        }
    }

    private func contactRow(_ match: ContactMatch) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: match.contactName, size: 36, imageData: match.avatarData)
            VStack(alignment: .leading, spacing: 2) {
                Text(match.contactName).font(.body.weight(.semibold)).foregroundStyle(.white)
                Text("@\(match.username)").font(.caption).foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 8)
            if match.hasConversation {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .accessibilityLabel("Chat started")
            } else if starting == match.id {
                ProgressView().tint(.white)
            } else {
                Button("Message") { message(match) }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.14), in: .capsule)
                    .disabled(starting != nil)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func check() {
        contacts = .checking
        Task {
            switch await ContactFinder.find(service: service) {
            case .denied: contacts = .denied
            case .failed(let message): contacts = .failed(message)
            case .found(let matches): contacts = .found(matches)
            }
        }
    }

    /// Starts the chat now; it's waiting in the list when setup ends.
    private func message(_ match: ContactMatch) {
        starting = match.id
        Task {
            defer { starting = nil }
            guard (try? await service.startConversation(username: match.username)) != nil,
                  case .found(var matches) = contacts,
                  let i = matches.firstIndex(where: { $0.id == match.id })
            else { return }
            matches[i].hasConversation = true
            contacts = .found(matches)
        }
    }

    /// A few faces around a chat bubble: the people this page is about.
    private var hero: some View {
        ZStack {
            ForEach(Array(Self.faces.enumerated()), id: \.offset) { i, face in
                Circle()
                    .fill(face.colour.gradient)
                    .frame(width: face.size, height: face.size)
                    .overlay { Text(face.letter).font(.system(size: face.size * 0.42, weight: .semibold, design: .rounded)).foregroundStyle(.white) }
                    .overlay { Circle().strokeBorder(.black.opacity(0.25), lineWidth: 2) }
                    .offset(x: face.x, y: face.y)
            }
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(tint, in: .circle)
                .shadow(color: tint.opacity(0.5), radius: 16)
        }
        .frame(height: 110)
        .accessibilityHidden(true)
    }

    private static let faces: [(letter: String, colour: Color, size: CGFloat, x: CGFloat, y: CGFloat)] = [
        ("A", .orange, 40, -78, -14), ("M", .blue, 34, 74, -22), ("J", .teal, 30, -46, 36), ("S", .purple, 36, 58, 30),
    ]

    private func tile(_ title: String, symbol: String, colour: Color, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(colour, in: .rect(cornerRadius: 11, style: .continuous))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 20, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func action(_ title: String, detail: String, icon: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(tint, in: .rect(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(.white)
                    Text(detail).font(.caption).foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Done

private struct SetupDonePage: View {
    let onFinish: () -> Void
    @Environment(ChatAppearance.self) private var environmentAppearance
    private var tint: Color { (ChatAppearance.app ?? environmentAppearance).bubbleTint }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().fill(tint.opacity(0.18)).frame(width: 150, height: 150)
                    .scaleEffect(appeared ? 1 : 0.6)
                Circle().fill(tint.opacity(0.3)).frame(width: 112, height: 112)
                    .scaleEffect(appeared ? 1 : 0.6)
                Image(systemName: "checkmark")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 80, height: 80)
                    .background(tint, in: .circle)
                    .shadow(color: tint.opacity(0.6), radius: 20)
                    .scaleEffect(appeared ? 1 : 0.4)
            }
            .padding(.top, 36)
            .accessibilityHidden(true)

            OnboardingHeader(title: "You're All Set", subtitle: "Say hi to someone. Only the two of you will ever read it.")

            VStack(alignment: .leading, spacing: 14) {
                point("lock.fill", "Private by default", "Messages and calls are end-to-end encrypted.")
                point("slider.horizontal.3", "Change anything later", "Everything you just picked is in Settings.")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onboardingCard()

            OnboardingPrimaryButton(title: "Start Using Relay", action: onFinish)
                .padding(.top, 6)
        }
        .onAppear {
            if reduceMotion { appeared = true } else {
                withAnimation(.spring(duration: 0.6, bounce: 0.45)) { appeared = true }
            }
        }
    }

    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Text(detail).font(.caption).foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}

// MARK: - Shared

private func label(_ text: String) -> some View {
    Text(text)
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.white.opacity(0.6))
        .padding(.leading, 4)
}

private var divider: some View {
    Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5).padding(.leading, 16)
}
