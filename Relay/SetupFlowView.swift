//
//  SetupFlowView.swift
//  Relay
//
//  A few pages after a new account is made, in the sign-in style: how Relay
//  looks, notifications, privacy, and a way to get the first chat going.
//  Every choice is one Settings also has, and each page can be skipped.
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

    private enum Page: Int, CaseIterable { case look, notifications, privacy, start }

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
                        case .start: SetupStartPage(service: service, onFinish: onFinish)
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
                if page != .start {
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
    @AppStorage(AppColorScheme.key) private var colorScheme = AppColorScheme.system.rawValue

    private var app: ChatAppearance { ChatAppearance.app ?? environmentAppearance }

    var body: some View {
        VStack(spacing: 16) {
            OnboardingHeader(title: "Make It Yours", subtitle: "Pick how Relay looks. You can change this any time in Settings → Appearance.")

            VStack(alignment: .leading, spacing: 10) {
                label("Appearance")
                HStack(spacing: 10) {
                    ForEach(AppColorScheme.allCases) { option in
                        schemeButton(option)
                    }
                }
            }

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

    private func schemeButton(_ option: AppColorScheme) -> some View {
        let selected = colorScheme == option.rawValue
        return Button {
            colorScheme = option.rawValue
        } label: {
            VStack(spacing: 8) {
                Image(systemName: option == .system ? "circle.lefthalf.filled" : option == .light ? "sun.max.fill" : "moon.fill")
                    .font(.system(size: 22, weight: .medium))
                Text(option.title).font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white.opacity(selected ? 1 : 0.6))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .onboardingCard()
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(selected ? Color.white.opacity(0.9) : .clear, lineWidth: 2)
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

// MARK: - Get started

private struct SetupStartPage: View {
    let service: MessagingService
    let onFinish: () -> Void
    @Environment(AppModel.self) private var model
    @State private var showingInvite = false

    var body: some View {
        VStack(spacing: 16) {
            OnboardingHeader(title: "You're All Set", subtitle: "Bring your people over and start your first chat.")

            VStack(spacing: 0) {
                action("Invite Friends", detail: "Send your link to people you talk to.", icon: "person.badge.plus") {
                    showingInvite = true
                }
                divider
                action("Import WhatsApp Chats", detail: "Keep your history: export a chat from WhatsApp to Relay.", icon: "square.and.arrow.down.on.square") {
                    onFinish()
                    model.pendingWhatsAppImport = true
                }
                divider
                action("Find People on Relay", detail: "Search by username or scan a QR code.", icon: "magnifyingglass") {
                    onFinish()
                    model.pendingCompose = true
                }
            }
            .onboardingCard()

            OnboardingPrimaryButton(title: "Start Using Relay", action: onFinish)
                .padding(.top, 8)
        }
        .sheet(isPresented: $showingInvite) {
            InviteShareSheet(username: service.username)
                .ignoresSafeArea()
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
