//
//  SetupFlowView.swift
//  Relay
//
//  A few pages after a new account is made, shown in place of the chat list
//  until they're done: how Relay looks, notifications, privacy, and finding
//  people to talk to. Every choice is one Settings also has, and each page can
//  be skipped. Built from DSComponents.
//

import SwiftUI
import UIKit

/// Light, Dark or the system's, for the app (sign-in pages are always dark).
enum AppColorScheme: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "relay.colorScheme"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }
    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct SetupFlowView: View {
    let service: MessagingService
    let onFinish: () -> Void

    private enum Page: Int, CaseIterable { case look, notifications, privacy, people, done }

    @State private var page = Page.look
    @State private var forward = true

    var body: some View {
        DSPage {
            Group {
                switch page {
                case .look: SetupLookPage()
                case .notifications: SetupNotificationsPage()
                case .privacy: SetupPrivacyPage(service: service)
                case .people: SetupPeoplePage(service: service)
                case .done: SetupDonePage()
                }
            }
            .id(page)
            .transition(.asymmetric(
                insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
        } footer: {
            Button(page == .done ? "Start Using Relay" : "Continue") {
                if page == .done { onFinish() } else { go(+1) }
            }
            .buttonStyle(.dsPrimary)
        }
        .safeAreaInset(edge: .top) { topBar }
        .animation(.spring(duration: 0.45), value: page)
    }

    private var topBar: some View {
        HStack {
            Button("Back") { go(-1) }
                .opacity(page == .look ? 0 : 1)
                .disabled(page == .look)
            Spacer()
            DSStepDots(count: Page.allCases.count, current: page.rawValue)
            Spacer()
            Button("Skip") { onFinish() }
                .opacity(page == .done ? 0 : 1)
                .disabled(page == .done)
        }
        .font(.body)
        .tint(.accentColor)
        .padding(.horizontal, DS.Spacing.xl)
        .padding(.vertical, DS.Spacing.sm)
        .background(Color(.systemGroupedBackground))
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
    @AppStorage(AppColorScheme.key) private var colorScheme = AppColorScheme.system.rawValue

    private var app: ChatAppearance { ChatAppearance.app ?? environmentAppearance }

    var body: some View {
        DSHeadline(title: "Make it", accent: "yours",
                   subtitle: "Pick how Relay looks. You can change this any time in Settings.")

        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            groupLabel("Appearance")
            HStack(spacing: DS.Spacing.md) {
                ForEach(AppColorScheme.allCases) { option in schemeButton(option) }
            }
        }

        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            groupLabel("Chat Theme")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Spacing.md) {
                    ThemeCard(theme: Self.relayTheme, isSelected: isSelected(Self.relayTheme)) { apply(Self.relayTheme) }
                    ForEach(ChatAppearance.themes) { theme in
                        ThemeCard(theme: theme, isSelected: isSelected(theme)) { apply(theme) }
                    }
                }
                .padding(.vertical, DS.Spacing.xs)
                .padding(.horizontal, 1)
            }
            .scrollClipDisabled()
        }
    }

    /// No wallpaper, Relay's own colour.
    static let relayTheme = AppearanceTheme(id: "relay", name: "Relay", wallpaper: .none, bubbleKey: nil)

    private func isSelected(_ theme: AppearanceTheme) -> Bool {
        app.wallpaper == theme.wallpaper && app.bubbleTintHex == theme.bubbleKey
    }

    private func apply(_ theme: AppearanceTheme) {
        withAnimation(DS.Motion.snappy) { app.applyTheme(theme) }
    }

    private func schemeButton(_ option: AppColorScheme) -> some View {
        let selected = colorScheme == option.rawValue
        return Button {
            withAnimation(DS.Motion.smooth) { colorScheme = option.rawValue }
        } label: {
            VStack(spacing: DS.Spacing.sm) {
                Image(systemName: option.symbol).font(.title2)
                Text(option.title).font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(selected ? Color.accentColor : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.lg)
            .background(Color(.secondarySystemGroupedBackground),
                        in: .rect(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Notifications

private struct SetupNotificationsPage: View {
    private var permission = NotificationPermission.shared
    @State private var preview = NotificationPreviewSetting.current

    var body: some View {
        DSHeadline(title: "Never miss a", accent: "message",
                   subtitle: "Know when someone messages or calls you, and choose what the lock screen shows.")

        DSGroup {
            DSToggleRow(label: DSRowLabel("Allow Notifications", icon: "bell.badge.fill", color: .red),
                        isOn: Binding(
                            get: { !permission.isOff },
                            set: { on in if on { NotificationPermission.shared.turnOn(using: AppDelegate.current) } }))
        }

        DSGroup(label: "Show in Notifications", separatorInset: DS.Spacing.lg) {
            choice("Name and Message", "Who it's from and what they said.", .full)
            choice("Name Only", "Who it's from, not what they said.", .nameOnly)
            choice("Nothing", "Just \"New message\".", .none)
        }
        .onAppear { permission.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            permission.refresh()
        }
    }

    private func choice(_ title: String, _ detail: String, _ value: NotificationPreviewSetting) -> some View {
        DSChoiceRow(title: title, subtitle: detail, isSelected: preview == value) {
            preview = value
            NotificationPreviewSetting.set(value)
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

    var body: some View {
        DSHeadline(title: "Your", accent: "privacy",
                   subtitle: "Messages are always end-to-end encrypted. These choose what else people can see.")

        DSGroup {
            DSToggleRow(label: DSRowLabel("Read Receipts", subtitle: "Show people when you've read their messages.",
                                          icon: "checkmark.circle.fill", color: .blue),
                        isOn: Binding(get: { readReceipts }, set: { readReceipts = $0; service.sendReadReceipts = $0 }))
            DSToggleRow(label: DSRowLabel("Typing Indicators", subtitle: "Show people when you're typing.",
                                          icon: "ellipsis.bubble.fill", color: .green),
                        isOn: $sendTyping)
            DSToggleRow(label: DSRowLabel("Link Previews", subtitle: "Your iPhone fetches them, not Relay.",
                                          icon: "link", color: .orange),
                        isOn: $linkPreviews)
            DSToggleRow(label: DSRowLabel("App Lock", subtitle: "Face ID or your passcode to open Relay.",
                                          icon: "faceid", color: .indigo),
                        isOn: $appLock)
        }

        DSGroup(label: "In the App Switcher", separatorInset: DS.Spacing.lg) {
            ForEach(AppSwitcherPrivacy.Mode.allCases) { mode in
                DSChoiceRow(title: mode.title, isSelected: appSwitcherMode == mode.rawValue) {
                    appSwitcherMode = mode.rawValue
                }
            }
        }
        .onAppear { readReceipts = service.sendReadReceipts }
    }
}

// MARK: - People

private struct SetupPeoplePage: View {
    let service: MessagingService
    @Environment(AppModel.self) private var model

    private enum ContactsState { case idle, checking, denied, failed(String), found([ContactMatch]) }

    @State private var contacts = ContactsState.idle
    @State private var showingConsent = false
    @State private var starting: String?
    @State private var showingImport = false
    @State private var showingInvite = false

    var body: some View {
        DSHeadline(title: "Find your", accent: "people", subtitle: subtitle)

        contactsGroup

        DSGroup {
            DSNavigationRow(label: DSRowLabel("Import WhatsApp Chats", subtitle: "Bring your history over.",
                                              icon: "square.and.arrow.down.on.square.fill", color: .green)) {
                showingImport = true
            }
            DSNavigationRow(label: DSRowLabel("Invite Friends", subtitle: "Send your link to people you talk to.",
                                              icon: "person.badge.plus", color: .pink)) {
                showingInvite = true
            }
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
        .sheet(isPresented: $showingImport) { WhatsAppImportView(service: service) }
        .sheet(isPresented: $showingInvite) {
            InviteShareSheet(username: service.username).ignoresSafeArea()
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

    @ViewBuilder private var contactsGroup: some View {
        switch contacts {
        case .idle:
            DSGroup(footer: "Their emails and phone numbers are blinded on your iPhone first, and your address book never leaves it.") {
                DSNavigationRow(label: DSRowLabel("Find Contacts on Relay", icon: "person.crop.circle.badge.checkmark", color: .blue)) {
                    ContactDiscoveryConsent.isGranted ? check() : (showingConsent = true)
                }
            }
        case .checking:
            DSGroup {
                HStack(spacing: DS.Spacing.md) {
                    ProgressView()
                    Text("Checking your contacts…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .dsRowPadding()
            }
        case .denied:
            DSGroup(footer: "Allow Contacts for Relay in Settings to see who's here.") {
                DSNavigationRow(label: DSRowLabel("Open Settings", icon: "gear", color: .gray)) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        case .failed(let message):
            DSGroup(footer: message) {
                DSNavigationRow(label: DSRowLabel("Try Again", icon: "arrow.clockwise", color: .blue)) { check() }
            }
        case .found(let matches):
            if !matches.isEmpty {
                DSGroup(label: "On Relay") {
                    ForEach(matches) { match in contactRow(match) }
                }
            }
        }
    }

    private func contactRow(_ match: ContactMatch) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            DSRowLabel(title: match.contactName, subtitle: "@\(match.username)") {
                AvatarView(name: match.contactName, size: DS.Avatar.sm, imageData: match.avatarData)
            }
            if match.hasConversation {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .accessibilityLabel("Chat started")
            } else if starting == match.id {
                ProgressView()
            } else {
                Button("Message") { message(match) }
                    .buttonStyle(.dsPill)
                    .disabled(starting != nil)
            }
        }
        .dsRowPadding()
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
}

// MARK: - Done

private struct SetupDonePage: View {
    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.system(size: 64))
            .foregroundStyle(Color.accentColor)
            .symbolRenderingMode(.hierarchical)
            .padding(.top, DS.Spacing.xxxl)
            .accessibilityHidden(true)
        DSHeadline(title: "You're all", accent: "set",
                   subtitle: "Everything you send is end-to-end encrypted. Change any of this later in Settings.")
    }
}

// MARK: - Shared

private func groupLabel(_ text: String) -> some View {
    Text(text.uppercased())
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.leading, DS.Spacing.lg)
}
