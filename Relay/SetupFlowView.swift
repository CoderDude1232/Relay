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

    private enum Page: Int, CaseIterable { case look, notifications, privacy, people, done }

    @State private var page = Page.look
    @State private var forward = true

    var body: some View {
        ZStack {
            BackgroundGradient()
            VStack(spacing: 0) {
                topBar
                ScrollView {
                    Group {
                        switch page {
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
                    OnboardingPrimaryButton(title: "Continue") { go(+1) }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                        .frame(maxWidth: 480)
                }
            }
        }
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
        .animation(.spring(duration: 0.45), value: page)
    }

    private var topBar: some View {
        HStack {
            if page != .look {
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
                ForEach(Page.allCases, id: \.self) { p in
                    Capsule()
                        .fill(.white.opacity(p == page ? 0.9 : 0.25))
                        .frame(width: p == page ? 18 : 6, height: 6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \(page.rawValue + 1) of \(Page.allCases.count)")
            Spacer()
            Button("Skip") { onFinish() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 40, height: 40)
                .opacity(page == .done ? 0 : 1)
                .disabled(page == .done)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }

    private func go(_ step: Int) {
        guard let next = Page(rawValue: page.rawValue + step) else { return }
        forward = step > 0
        page = next
    }
}

// MARK: - Look

private struct SetupLookPage: View {
    @Environment(ChatAppearance.self) private var environmentAppearance
    private var app: ChatAppearance { ChatAppearance.app ?? environmentAppearance }

    var body: some View {
        VStack(spacing: 16) {
            OnboardingHeader(title: "Make It Yours", subtitle: "Pick a theme for your chats. You can change it any time in Settings → Appearance, or give a chat its own.")

            VStack(alignment: .leading, spacing: 10) {
                label("Chat Theme")
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
        VStack(spacing: 16) {
            OnboardingHeader(title: "Notifications", subtitle: "Know when someone messages or calls you, and choose what the lock screen shows.")

            if permission.isOff {
                OnboardingPrimaryButton(title: permission.status == .denied ? "Turn On in Settings" : "Turn On Notifications") {
                    NotificationPermission.shared.turnOn(using: AppDelegate.current)
                }
            } else {
                Label("Notifications are on", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .onboardingCard()
            }

            VStack(alignment: .leading, spacing: 10) {
                label("Show in Notifications")
                VStack(spacing: 0) {
                    choice("Name and Message", detail: "Who it's from and what they said.", value: .full)
                    divider
                    choice("Name Only", detail: "Who it's from, not what they said.", value: .nameOnly)
                    divider
                    choice("Nothing", detail: "Just \"New message\".", value: .none)
                }
                .onboardingCard()
            }
        }
        .onAppear { permission.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            permission.refresh()
        }
    }

    private func choice(_ title: String, detail: String, value: NotificationPreviewSetting) -> some View {
        Button {
            preview = value
            NotificationPreviewSetting.set(value)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body).foregroundStyle(.white)
                    Text(detail).font(.caption).foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 8)
                if preview == value {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(preview == value ? .isSelected : [])
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

    var body: some View {
        VStack(spacing: 16) {
            OnboardingHeader(title: "Privacy", subtitle: "Messages are always end-to-end encrypted. These choose what else others can see.")

            VStack(spacing: 0) {
                toggle("Read Receipts", detail: "Let people see when you've read their messages.", icon: "checkmark.circle", isOn: Binding(
                    get: { readReceipts },
                    set: { readReceipts = $0; service.sendReadReceipts = $0 }))
                divider
                toggle("Typing Indicators", detail: "Let people see when you're typing.", icon: "ellipsis.bubble", isOn: $sendTyping)
                divider
                toggle("Link Previews", detail: "Show a preview of links you send. Your iPhone fetches it, not Relay.", icon: "link", isOn: $linkPreviews)
            }
            .onboardingCard()

            toggle("App Lock", detail: "Ask for Face ID or your passcode to open Relay.", icon: "faceid", isOn: $appLock)
                .onboardingCard()

            VStack(alignment: .leading, spacing: 10) {
                label("In the App Switcher")
                VStack(spacing: 0) {
                    ForEach(Array(AppSwitcherPrivacy.Mode.allCases.enumerated()), id: \.element) { index, mode in
                        if index > 0 { divider }
                        Button { appSwitcherMode = mode.rawValue } label: {
                            HStack {
                                Text(mode.title).foregroundStyle(.white)
                                Spacer()
                                if appSwitcherMode == mode.rawValue {
                                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.white)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(appSwitcherMode == mode.rawValue ? .isSelected : [])
                    }
                }
                .onboardingCard()
            }
        }
        .onAppear { readReceipts = service.sendReadReceipts }
    }

    private func toggle(_ title: String, detail: String, icon: String, isOn: Binding<Bool>) -> some View {
        OnboardingRow(icon: icon) {
            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.white)
                    Text(detail).font(.caption).foregroundStyle(.white.opacity(0.55))
                }
            }
            .tint(Color(red: 0.965, green: 0.231, blue: 1.0))
        }
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

    var body: some View {
        VStack(spacing: 16) {
            OnboardingHeader(title: "Find Your People", subtitle: subtitle)

            contactsCard

            VStack(spacing: 0) {
                action("Import WhatsApp Chats", detail: "Keep your history: export a chat from WhatsApp to Relay.", icon: "square.and.arrow.down.on.square") {
                    showingImport = true
                }
                divider
                action("Invite Friends", detail: "Send your link to people you talk to.", icon: "person.badge.plus") {
                    showingInvite = true
                }
            }
            .onboardingCard()
        }
        .alert("Find Contacts on Relay?", isPresented: $showingConsent) {
            Button("Find Contacts") {
                ContactDiscoveryConsent.grant()
                check()
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text(ContactDiscoveryConsent.explanation)
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
            action("Find Contacts on Relay", detail: "Check which of your contacts use Relay. They're blinded on your iPhone first.", icon: "person.crop.circle.badge.checkmark") {
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
            action("Allow Contacts in Settings", detail: "Relay needs access to your contacts to see who's here.", icon: "gear") {
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

    private func action(_ title: String, detail: String, icon: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.12), in: .circle)
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

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(.white)
                .symbolRenderingMode(.hierarchical)
                .padding(.top, 48)
                .accessibilityHidden(true)
            OnboardingHeader(title: "You're All Set", subtitle: "Everything you send is end-to-end encrypted. Change any of this later in Settings.")
            OnboardingPrimaryButton(title: "Start Using Relay", action: onFinish)
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
