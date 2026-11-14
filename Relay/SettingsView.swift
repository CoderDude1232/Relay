//
//  SettingsView.swift
//  Relay
//

import Intents
import LocalAuthentication
import PhotosUI
import RelayCore
import RelayKit
import SwiftUI
import UIKit

struct SettingsView: View {
    let service: MessagingService

    @Environment(AppModel.self) private var model
    @Environment(ChatAppearance.self) private var appearance
    @State private var confirmingSignOut = false
    @State private var showingEditProfile = false
    @State private var avatarData: Data?
    @State private var panicMode = PanicModeManager.shared
    @State private var showingPanicSettings = false
    @State private var versionTapCount = 0
    @State private var showingInvite = false
    @State private var showingSupporter = false
    @State private var showingQR = false
    @State private var settingsQuery = ""
    /// The page open beside the list on iPad, so its row stays highlighted.
    @State private var openPage: String?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var displayName: String {
        let name = service.myDisplayName ?? service.username
        return name?.isEmpty == false ? name! : "Unknown"
    }

    var body: some View {
        AdaptiveNavigation {
            List {

                // MARK: Profile
                Section {
                    Button { showingEditProfile = true } label: {
                        HStack(spacing: 14) {
                            ZStack(alignment: .bottomTrailing) {
                                AvatarView(name: displayName, size: 64, imageData: avatarData)
                                AvatarEditBadge(systemImage: "pencil", diameter: 22)
                                    .offset(x: 2, y: 2)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(displayName)
                                        .font(.title3.bold())
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if Supporter.shared.isActive {
                                        Image(systemName: "heart.fill")
                                            .font(.subheadline)
                                            .foregroundStyle(.pink)
                                            .accessibilityLabel("Relay Supporter")
                                    }
                                }
                                if let username = service.username {
                                    Text("@\(username)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                        .contentShape(.rect) // the whole row, not just the text
                    }
                    .buttonStyle(.plain)
                    .tint(.primary)
                    .listRowBackground(rowHighlight("profile"))
                    if !service.isDemoAccount, service.username != nil {
                        Button { showingQR = true } label: {
                            HStack(spacing: 14) {
                                SettingsIcon(systemName: "qrcode", color: .gray)
                                Text("My QR Code").foregroundStyle(.primary)
                            }
                        }
                        .tint(.primary)
                    }
                }

                // MARK: Categories
                // Niche tools (Scheduled Messages, Blocked) live inside Chats, and
                // storage/backup/sync inside Data & Storage, to keep this level short.
                Section {
                    if service.username != nil {
                        NavigationLink(destination: AccountSettingsView(service: service).markOpen("account", in: $openPage)) {
                            SettingsNavRow(systemName: "person.crop.circle.fill", color: .blue, title: "Account")
                        }
                        .listRowBackground(rowHighlight("account"))
                    }
                    NavigationLink(destination: AppearanceSettingsView().markOpen("appearance", in: $openPage)) {
                        SettingsNavRow(systemName: "paintbrush.fill", color: .purple, title: "Appearance")
                    }
                    .listRowBackground(rowHighlight("appearance"))
                    NavigationLink(destination: ChatsSettingsView(service: service).markOpen("chats", in: $openPage)) {
                        SettingsNavRow(systemName: "bubble.left.and.bubble.right.fill", color: .green, title: "Chats")
                    }
                    .listRowBackground(rowHighlight("chats"))
                    NavigationLink(destination: NotificationSettingsView(service: service).markOpen("notifications", in: $openPage)) {
                        SettingsNavRow(systemName: "bell.badge.fill", color: .red, title: "Notifications")
                    }
                    .listRowBackground(rowHighlight("notifications"))
                    NavigationLink(destination: PrivacySettingsView(service: service).markOpen("privacy", in: $openPage)) {
                        SettingsNavRow(systemName: "hand.raised.fill", color: .indigo, title: "Privacy")
                    }
                    .listRowBackground(rowHighlight("privacy"))
                    NavigationLink(destination: SecuritySettingsView(service: service).markOpen("security", in: $openPage)) {
                        SettingsNavRow(systemName: "lock.shield.fill", color: .teal, title: "Security")
                    }
                    .listRowBackground(rowHighlight("security"))
                    NavigationLink(destination: DataStorageSettingsView(service: service).markOpen("data", in: $openPage)) {
                        SettingsNavRow(systemName: "internaldrive.fill", color: .orange, title: "Data & Storage")
                    }
                    .listRowBackground(rowHighlight("data"))
                }

                // MARK: Invite and support
                // Privacy Policy, Terms and Acknowledgements live under About.
                Section {
                    // Hidden on demo accounts, which can't reach real users.
                    if !service.isDemoAccount {
                    Button {
                        showingInvite = true
                    } label: {
                        HStack(spacing: 14) {
                            SettingsIcon(systemName: "person.badge.plus", color: .green)
                            Text("Invite Friends").foregroundStyle(.primary)
                        }
                    }
                    .tint(.primary)
                    .sheet(isPresented: $showingInvite) {
                        InviteShareSheet(username: service.username)
                            .ignoresSafeArea()
                    }
                    }
                    if Supporter.shared.isOffered {
                    Button { showingSupporter = true } label: {
                        HStack(spacing: 14) {
                            SettingsIcon(systemName: "heart.fill", color: .pink)
                            Text("Support Relay").foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            if Supporter.shared.isActive {
                                Text("Supporter").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tint(.primary)
                    .sheet(isPresented: $showingSupporter) { SupporterView() }
                    }
                    Link(destination: LegalLinks.feedbackMail) {
                        SettingsExternalRow(systemName: "envelope.fill", color: .blue, title: "Send Feedback")
                    }
                    .tint(.primary)
                    NavigationLink(destination: AboutSettingsView(appVersion: appVersion).markOpen("about", in: $openPage)) {
                        SettingsNavRow(systemName: "info.circle.fill", color: .gray, title: "About")
                    }
                    .listRowBackground(rowHighlight("about"))
                }

                // MARK: Sign out
                Section {
                    Button(role: .destructive) {
                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                        confirmingSignOut = true
                    } label: {
                        HStack(spacing: 14) {
                            SettingsIcon(systemName: "rectangle.portrait.and.arrow.right", color: .red)
                            Text("Sign Out").foregroundStyle(.red)
                        }
                    }
                    .confirmationDialog(
                        "Sign out of Relay?",
                        isPresented: $confirmingSignOut,
                        titleVisibility: .visible
                    ) {
                        Button("Sign Out", role: .destructive) {
                            model.signOut()
                        }
                    } message: {
                        Text(service.keepsChatListWithAccount && MessagingService.isHistoryBackupEnabled
                             ? "You can sign back in anytime. Your chats are removed from this iPhone and come back from your backup when you do."
                             : "You can sign back in anytime, but your chats are erased from this iPhone and won't come back, because Message Backup is off. To keep them, turn it on in Data & Storage first.")
                    }
                } footer: {
                    Text("Relay \(appVersion)")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                        .onTapGesture {
                            versionTapCount += 1
                            if versionTapCount >= 5 {
                                versionTapCount = 0
                                showingPanicSettings = true
                            }
                        }
                }
            }
            // In the iPad sidebar a List defaults to the sidebar style: square,
            // edge-to-edge sections. Rounded cards, like the pages beside it.
            .listStyle(.insetGrouped)
            .overlay {
                if !settingsQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                    settingsSearchResults
                }
            }
            .searchable(text: $settingsQuery, placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: "Search settings")
            .navigationTitle("Profile")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ConnectionBadge(state: service.connectionState)
                }
            }
            .onAppear { avatarData = service.myAvatarData }
            .sheet(isPresented: $showingQR) {
                MyQRCodeView(username: service.username ?? "", displayName: service.myDisplayName,
                             avatarData: service.myAvatarData, createInviteLink: {
                    try await service.createContactInviteLink()
                })
            }
            .navigationDestination(isPresented: $showingEditProfile) {
                EditProfileSheet(service: service) { avatarData = service.myAvatarData }
                    .markOpen("profile", in: $openPage)
            }
            .navigationDestination(isPresented: $showingPanicSettings) {
                PanicModeSheet(manager: panicMode)
            }
        } placeholder: {
            profileCard
                .onAppear { openPage = nil }
        }
    }

    // MARK: Search

    private enum SettingsPage: String {
        case profile = "Profile", account = "Account", appearance = "Appearance", chats = "Chats"
        case privacy = "Privacy", security = "Security", data = "Data & Storage"
        case passkeys = "Passkeys", linkedDevices = "Linked Devices", blocked = "Blocked Contacts"
        case folders = "Chat Folders", scheduled = "Scheduled Messages", storage = "Storage"
        case proxy = "Proxy", contactSync = "Contact Syncing"
        case notifications = "Notifications", about = "About"
    }

    /// Every setting worth finding, with the page it lives on.
    private static let settingsIndex: [(title: String, keywords: String, page: SettingsPage)] = [
        ("Edit Profile", "name photo picture avatar bio about status links", .profile),
        ("Username", "handle change username", .profile),
        ("Account Password", "password sign in", .account),
        ("Email", "email address change remove find me by email", .account),
        ("Passkeys", "passkey face id sign in", .passkeys),
        ("Recovery Key", "recovery key backup sign in lost", .account),
        ("Linked Devices", "devices ipad mac link computer", .linkedDevices),
        ("Emergency Wipe All Devices", "nuke remote wipe erase", .account),
        ("Delete Account", "delete close account", .account),
        ("Theme", "theme colour color look", .appearance),
        ("Wallpaper", "wallpaper background photo", .appearance),
        ("Bubble Colour", "bubble color colour message", .appearance),
        ("In-Chat Sounds", "sound sounds audio", .chats),
        ("Undo Send", "undo unsend take back delay mistake", .chats),
        ("Chat Folders", "folders labels organise", .folders),
        ("Scheduled Messages", "schedule later send", .scheduled),
        ("Blocked Contacts", "block blocked unblock", .blocked),
        ("Read Receipts", "read receipts seen blue ticks", .privacy),
        ("Typing Indicators", "typing", .privacy),
        ("Link Previews", "link preview", .privacy),
        ("Incognito Keyboard", "keyboard autocorrect learning", .privacy),
        ("Notification Previews", "notifications lock screen preview banner", .notifications),
        ("Notification Delivery", "faster alerts push instant wake notifications", .notifications),
        ("Protect IP Address in Calls", "calls ip address relay-only relay only turn direct location", .chats),
        ("Show Calls in Recents", "calls recents phone app", .chats),
        ("Wi-Fi Only Downloads", "wifi media download cellular", .data),
        ("Scam Warnings", "scam fraud warning", .privacy),
        ("Send Delay", "delay timing jitter", .privacy),
        ("Proxy", "proxy blocked censorship connect", .proxy),
        ("Data & Retention", "retention server stores policy legal", .about),
        ("Privacy Policy", "privacy policy terms legal", .about),
        ("Acknowledgements", "open source licenses", .about),
        ("Screen Lock", "lock face id touch id passcode", .security),
        ("Panic Mode", "panic hide chats pin", .security),
        ("Relay PIN Lock", "pin lock distress duress erase wipe forget", .security),
        ("Message Backup", "backup history restore new phone", .data),
        ("Storage", "storage space cache media", .storage),
        ("Contact Syncing", "contacts sync address book", .contactSync),
    ]

    private var settingsMatches: [(title: String, keywords: String, page: SettingsPage)] {
        let q = settingsQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return Self.settingsIndex.filter {
            $0.title.lowercased().contains(q) || $0.keywords.contains(q) || $0.page.rawValue.lowercased().contains(q)
        }
    }

    private var settingsSearchResults: some View {
        List {
            if settingsMatches.isEmpty {
                ContentUnavailableView.search(text: settingsQuery)
                    .listRowBackground(Color.clear)
            }
            ForEach(settingsMatches, id: \.title) { match in
                NavigationLink {
                    page(match.page)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(match.title)
                        if match.page.rawValue != match.title {
                            Text(match.page.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .modifier(ThemedPageBackground())
        .background { if !appearance.hasWallpaper { Color(.systemGroupedBackground).ignoresSafeArea() } }
    }

    @ViewBuilder
    private func page(_ page: SettingsPage) -> some View {
        switch page {
        case .profile: EditProfileSheet(service: service) { avatarData = service.myAvatarData }
        case .account: AccountSettingsView(service: service)
        case .appearance: AppearanceSettingsView()
        case .chats: ChatsSettingsView(service: service)
        case .privacy: PrivacySettingsView(service: service)
        case .security: SecuritySettingsView(service: service)
        case .data: DataStorageSettingsView(service: service)
        case .passkeys: PasskeysView(service: service)
        case .linkedDevices: LinkedDevicesView(service: service)
        case .blocked: BlockedContactsView(service: service)
        case .folders: ChatFoldersView(service: service)
        case .scheduled: ScheduledMessagesView(service: service)
        case .storage: StorageSettingsView(service: service)
        case .proxy: ProxySettingsView()
        case .contactSync: ContactSyncView(service: service)
        case .notifications: NotificationSettingsView(service: service)
        case .about: AboutSettingsView(appVersion: appVersion)
        }
    }

    /// Beside the list on iPad, before a page is opened.
    private var profileCard: some View {
        VStack(spacing: 14) {
            AvatarView(name: displayName, size: 110, imageData: avatarData)
            VStack(spacing: 4) {
                Text(displayName)
                    .font(.title2.bold())
                if let username = service.username {
                    Text("@\(username)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Button("Edit Profile") { showingEditProfile = true }
                .buttonStyle(.bordered)
                .padding(.top, 4)
        }
        .padding()
    }

    /// The open page's row, highlighted on iPad like the open chat; every
    /// other row keeps the list's card background.
    @ViewBuilder
    private func rowHighlight(_ page: String) -> some View {
        if horizontalSizeClass == .regular, openPage == page {
            Color(.systemGray4)
        } else {
            // The list's normal card, so these rows match the rest.
            Color(.secondarySystemGroupedBackground)
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

}

// MARK: - Account sub-page

private struct AccountSettingsView: View {
    let service: MessagingService
    @Environment(AppModel.self) private var model
    @State private var accountEmail: String?
    @State private var showingQR = false
    @State private var linkCopied = false
    @State private var showingDeleteAccount = false
    @State private var confirmingNuke = false
    @State private var nukeInProgress = false
    @State private var nukeSucceeded = false
    @State private var nukeError: String?
    @State private var methods: SignInMethods?
    @State private var showingPhoneNumber = false
    @State private var phoneNumber = UserDefaults.standard.string(forKey: MessagingService.phoneNumberKey)

    private var username: String { service.username ?? "" }
    private var addLink: String { "relaymsg.app/add/\(username)" }
    /// Until the relay answers, go by the email this device signed in with.
    private var hasEmail: Bool { methods?.email ?? (accountEmail != nil) }

    /// "Off", the one method, or how many are on.
    static func twoStepLabel(_ methods: [TwoStepRequired.Method]) -> String {
        methods.count > 1 ? "\(methods.count) Methods" : twoStepLabel(methods.first)
    }

    static func twoStepLabel(_ method: TwoStepRequired.Method?) -> String {
        switch method {
        case nil: "Off"
        case .authenticator: "Authenticator"
        case .passkey: "Passkey"
        case .pin: "PIN"
        case .recovery: "Recovery Key"
        }
    }

    var body: some View {
        List {
            Section {
                SettingsHero(systemName: "person.crop.circle.fill", color: .blue, title: "Account",
                             message: "Your username, how you sign in, and how to get back in if you lose this iPhone.")
                    .settingsBareRow()
            }
            Section {
                if service.isDemoAccount {
                    LabeledContent("Username", value: "@\(username)")
                } else {
                    Menu {
                        Button {
                            SecurePasteboard.copy("https://\(addLink)")
                            linkCopied = true
                            Task { try? await Task.sleep(for: .seconds(2)); linkCopied = false }
                        } label: { Label("Copy Link", systemImage: "link") }
                        if let url = URL(string: "https://\(addLink)") {
                            ShareLink(item: url) { Label("Share Link", systemImage: "square.and.arrow.up") }
                        }
                        Button { showingQR = true } label: { Label("Show QR Code", systemImage: "qrcode") }
                    } label: {
                        HStack(spacing: 14) {
                            SettingsIcon(systemName: linkCopied ? "checkmark" : "at", color: .accentColor)
                            Text(linkCopied ? "Link Copied" : "Username").foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            Text("@\(username)").foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            } footer: {
                if service.isDemoAccount {
                    Text("A demo account for testing Relay. It can only message other demo accounts.")
                }
            }
            .tint(.primary)

            if !service.isDemoAccount {
                Section {
                    Button { showingPhoneNumber = true } label: {
                        HStack(spacing: 14) {
                            SettingsIcon(systemName: "phone.fill", color: .green)
                            Text("Phone Number").foregroundStyle(Color.primary)
                            Spacer(minLength: 0)
                            Text(phoneNumber.map { PhoneNumbers.display($0) } ?? (methods?.phone == true ? "Added" : "Add"))
                                .foregroundStyle(Color.secondary)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color(.tertiaryLabel))
                        }
                    }
                    if hasEmail {
                        NavigationLink(destination: ChangeEmailSheet(canRemove: (methods?.passkeys ?? 0) > 0) {
                            accountEmail = nil
                            Task { methods = try? await service.apiClient.signInMethods() }
                        }) {
                            HStack(spacing: 14) {
                                SettingsIcon(systemName: "envelope.fill", color: .blue)
                                Text("Email")
                                Spacer(minLength: 0)
                                Text(accountEmail ?? "Change")
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    NavigationLink(destination: PasskeysView(service: service)) {
                        HStack(spacing: 14) {
                            SettingsIcon(systemName: "person.badge.key.fill", color: .teal)
                            Text("Passkeys")
                            Spacer(minLength: 0)
                            if let count = methods?.passkeys, count > 0 {
                                Text("\(count)").foregroundStyle(.secondary)
                            }
                        }
                    }
                    NavigationLink(destination: TwoStepSettingsView(service: service)) {
                        HStack(spacing: 14) {
                            SettingsIcon(systemName: "lock.shield.fill", color: .indigo)
                            Text("Two-Step Verification")
                            Spacer(minLength: 0)
                            Text(Self.twoStepLabel(methods?.twoStepMethods ?? [])).foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink(destination: RecoveryKeyView(service: service, methods: methods)) {
                        SettingsNavRow(systemName: "key.horizontal.fill", color: .yellow, title: "Recovery Key")
                    }
                } header: {
                    Text("Sign-In & Security")
                } footer: {
                    Text("Sign in on a new device with any of these. Your recovery key works when nothing else does.")
                }
                .tint(.primary)
            }

            Section {
                NavigationLink(destination: LinkedDevicesView(service: service)) {
                    SettingsNavRow(systemName: "laptopcomputer.and.iphone", color: .orange, title: "Linked Devices")
                }
            }

            Section {
                if !service.isDemoAccount {
                    Button(role: .destructive) {
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                        confirmingNuke = true
                    } label: {
                        HStack(spacing: 14) {
                            SettingsIcon(systemName: "flame.fill", color: .red)
                            Text("Emergency Wipe All Devices").foregroundStyle(.red)
                            Spacer(minLength: 0)
                            if nukeInProgress { ProgressView() }
                        }
                    }
                    .disabled(nukeInProgress)
                }
                Button(role: .destructive) {
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    showingDeleteAccount = true
                } label: {
                    HStack(spacing: 14) {
                        SettingsIcon(systemName: "person.crop.circle.badge.xmark", color: .red)
                        Text(service.isDemoAccount ? "Reset Demo Account" : "Delete Account").foregroundStyle(.red)
                    }
                }
            }
        }
        .modifier(ThemedPageBackground())
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            accountEmail = model.accountEmail
            // Back from a sub-page (two-step, passkeys, email): show what changed.
            Task { methods = try? await service.apiClient.signInMethods() }
        }
        .sheet(isPresented: $showingQR) {
            MyQRCodeView(username: username, displayName: service.myDisplayName,
                         avatarData: service.myAvatarData, createInviteLink: {
                try await service.createContactInviteLink()
            })
        }
        .navigationDestination(isPresented: $showingPhoneNumber) {
            PhoneNumberView(service: service, context: .settings) { showingPhoneNumber = false }
        }
        .onChange(of: showingPhoneNumber) { _, showing in
            guard !showing else { return }
            phoneNumber = UserDefaults.standard.string(forKey: MessagingService.phoneNumberKey)
            Task { methods = try? await service.apiClient.signInMethods() }
        }
        .navigationDestination(isPresented: $showingDeleteAccount) {
            DeleteAccountSheet(service: service) {
                ICloudBackupKey.deleteAll()
                model.signOut(removeFromServer: false) // the account is already gone
            }
        }
        .confirmationDialog("Erase Relay on all your devices?", isPresented: $confirmingNuke, titleVisibility: .visible) {
            Button("Wipe All Devices", role: .destructive) {
                // Wiping every device must prove the owner is present, so
                // refuse when no passcode is set.
                guard BiometricGate.isPasscodeSet else {
                    nukeError = BiometricGate.passcodeRequiredMessage
                    return
                }
                nukeInProgress = true
                Task {
                    let ok = await BiometricGate.authenticate(
                        reason: "Confirm emergency wipe of all devices",
                        requirePasscode: true
                    )
                    guard ok else {
                        nukeInProgress = false
                        return
                    }
                    do {
                        try await service.sendNukeCommand()
                        nukeSucceeded = true
                    } catch {
                        nukeError = FriendlyError.message(for: error)
                    }
                    nukeInProgress = false
                }
            }
        } message: {
            Text("Every device signed in to your account erases its messages and encryption keys. A device that's switched off or offline may be missed. This can't be undone.")
        }
        .alert("Emergency Wipe Sent", isPresented: $nukeSucceeded) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your devices that are online now are erasing their messages and keys.")
        }
        .alert("Emergency Wipe Failed", isPresented: Binding(
            get: { nukeError != nil },
            set: { if !$0 { nukeError = nil } }
        )) {
            Button("OK", role: .cancel) { nukeError = nil }
        } message: {
            Text(nukeError ?? "")
        }
    }
}

// MARK: - Chats sub-page

private struct ChatsSettingsView: View {
    let service: MessagingService
    @Environment(AppModel.self) private var model
    @Environment(CallManager.self) private var callManager
    @State private var privateCallMode = CallManager.isPrivateCallModeEnabled
    @State private var showDirectCallsWarning = false
    @AppStorage(CallManager.callsInRecentsKey) private var callsInRecents = false
    @AppStorage(InChatSounds.enabledKey) private var inChatSounds = true
    @AppStorage(MessagingService.undoSendKey) private var undoSend = false
    @State private var importingWhatsApp = false

    var body: some View {
        List {
            Section {
                SettingsHero(systemName: "bubble.left.and.bubble.right.fill", color: .green, title: "Chats",
                             message: "Sounds, folders, calls, scheduled messages and blocked contacts.")
                    .settingsBareRow()
            }
            Section {
                Toggle(isOn: $inChatSounds) {
                    HStack(spacing: 14) {
                        SettingsIcon(systemName: "speaker.wave.2.fill", color: .pink)
                        Text("In-Chat Sounds")
                    }
                }
            } footer: {
                Text("A short sound when a message is sent or arrives in the chat you have open. Follows your ring/silent switch.")
            }

            Section {
                SettingsToggleRow(systemName: "arrow.uturn.backward.circle.fill", color: .blue, title: "Undo Send",
                                  isOn: $undoSend)
            } footer: {
                Text("Waits 5 seconds before a message goes out, so you can take it back. Long-press Send to send without sound.")
            }

            Section {
                NavigationLink(destination: ChatFoldersView(service: service)) {
                    SettingsNavRow(systemName: "folder.fill", color: .blue, title: "Chat Folders")
                }
                NavigationLink(destination: ScheduledMessagesView(service: service)) {
                    SettingsNavRow(systemName: "clock.badge.checkmark", color: .orange, title: "Scheduled Messages")
                }
                NavigationLink(destination: BlockedContactsView(service: service)) {
                    SettingsNavRow(systemName: "person.crop.circle.badge.minus", color: .red, title: "Blocked Contacts")
                }
            } footer: {
                Text("Folders stay on this device. Blocked accounts can't message or call you.")
            }

            Section {
                SettingsToggleRow(systemName: "phone.fill", color: .green, title: "Protect IP Address in Calls",
                                  isOn: Binding(get: { privateCallMode }, set: { newValue in
                                      if newValue {
                                          privateCallMode = true
                                          callManager.privateCallMode = true
                                      } else {
                                          showDirectCallsWarning = true
                                      }
                                  }))
                SettingsToggleRow(systemName: "clock.arrow.circlepath", color: .green, title: "Show Calls in Recents",
                                  isOn: $callsInRecents)
            } header: {
                Text("Calls")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if privateCallMode {
                        Text("Calls pass through a server, so the people you call can't see your IP address, which can show roughly where you are.")
                    } else {
                        Text("Off: the people you call can see your IP address, which can show roughly where you are.")
                            .foregroundStyle(.red)
                    }
                    Text("Show Calls in Recents lists Relay calls in the Phone app, which can sync them to your other Apple devices through iCloud.")
                }
            }
            .confirmationDialog("Stop protecting your IP address?", isPresented: $showDirectCallsWarning, titleVisibility: .visible) {
                Button("Turn Off", role: .destructive) {
                    privateCallMode = false
                    callManager.privateCallMode = false
                }
                Button("Keep On", role: .cancel) {}
            } message: {
                Text("Calls may connect a little faster, but the people you call will see your IP address, which can show roughly where you are.")
            }

            Section {
                Button { importingWhatsApp = true } label: {
                    SettingsNavRow(systemName: "square.and.arrow.down.on.square.fill", color: .green, title: "Import from WhatsApp")
                }
                .foregroundStyle(.primary)
                .sheet(isPresented: $importingWhatsApp) {
                    WhatsAppImportView(service: service) { conversationId in
                        model.pendingNotificationConversationId = conversationId
                    }
                }
            } footer: {
                Text("Bring a chat's history over from WhatsApp. It stays on this iPhone.")
            }
        }
        .modifier(ThemedPageBackground())
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Data & Storage sub-page

private struct DataStorageSettingsView: View {
    let service: MessagingService
    @AppStorage(MessagingService.historyBackupEnabledKey) private var historyBackup = true

    var body: some View {
        List {
            Section {
                SettingsHero(systemName: "internaldrive.fill", color: .orange, title: "Data & Storage",
                             message: "Your encrypted backup, what's stored on this iPhone, and contact syncing.")
                    .settingsBareRow()
            }
            Section {
                NavigationLink(destination: StorageSettingsView(service: service)) {
                    SettingsNavRow(systemName: "internaldrive.fill", color: .gray, title: "Storage")
                }
                if service.isDemoAccount {
                    EmptyView()
                } else if service.keepsChatListWithAccount {
                    SettingsToggleRow(systemName: "clock.arrow.circlepath", color: .blue, title: "Message Backup",
                                      info: "Keeps an encrypted copy of your messages with your account, so they come back on a new phone. Only your password, passkey or recovery key can unlock it. Relay can't read it. Relay Supporters also back up photos and files. Disappearing and view-once messages, message requests and hidden chats are left out. Turning this off deletes the copy and stops backups on all your devices.",
                                      isOn: Binding(get: { historyBackup }, set: { enabled in
                                          historyBackup = enabled
                                          Task { await service.setHistoryBackupEnabled(enabled) }
                                      }))
                    if historyBackup {
                        HistoryBackupStatusRow(service: service)
                    } else if service.historyDeletionPending {
                        Label("Deleting your backup from Relay. It finishes next time you're online.",
                              systemImage: "clock.arrow.circlepath")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 14) {
                        SettingsIcon(systemName: "clock.arrow.circlepath", color: .blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Message Backup")
                            Text("Add a passkey, recovery key or account password in Account to back up your messages.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !service.isDemoAccount {
                    NavigationLink(destination: ContactSyncView(service: service)) {
                        SettingsNavRow(systemName: "person.crop.circle.badge.checkmark", color: .green, title: "Contact Syncing")
                    }
                }
            }
            Section {
                SettingsToggleRow(systemName: "wifi", color: .blue, title: "Wi-Fi Only Downloads",
                                  isOn: Binding(get: { UserDefaults.standard.bool(forKey: "relay.wifiOnlyDownload") },
                                                set: { UserDefaults.standard.set($0, forKey: "relay.wifiOnlyDownload") }))
            } header: {
                Text("Media")
            } footer: {
                Text("With Wi-Fi Only Downloads on, or while Low Data Mode is on, photos and videos wait for a tap instead of downloading by themselves.")
            }


            if service.preKeyDesyncDropCount > 0 {
                Section {
                    HStack(spacing: 14) {
                        SettingsIcon(systemName: "key.horizontal.fill", color: .accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Some messages couldn't be shown").foregroundStyle(.primary)
                            Text(service.preKeyDesyncDropCount == 1
                                 ? "1 message couldn't be opened. Relay has fixed this for new messages. If it was important, ask the sender to send it again."
                                 : "\(service.preKeyDesyncDropCount) messages couldn't be opened. Relay has fixed this for new messages. If they were important, ask the sender to send them again.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .modifier(ThemedPageBackground())
        .navigationTitle("Data & Storage")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Last backup, progress while one runs, the last error, and Back Up Now.
private struct HistoryBackupStatusRow: View {
    let service: MessagingService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress = service.historyBackupProgress {
                Text("Backing up…").font(.subheadline)
                ProgressView(value: progress)
                    .accessibilityLabel("Backup progress")
            } else {
                Text(lastBackupText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let error = service.historyBackupError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button("Back Up Now") {
                    Task { await service.backUpHistoryIfDue(force: true) }
                }
                .tint(.primary)
                .font(.subheadline.weight(.semibold))
                .disabled(!service.canBackUpHistory || service.connectionState != .connected)
            }
        }
        .padding(.vertical, 4)
        .animation(.easeInOut(duration: 0.2), value: service.historyBackupProgress == nil)
    }

    private var lastBackupText: String {
        guard let date = service.lastHistoryBackupDate else { return "Not backed up yet on this device." }
        let when: String
        if Calendar.current.isDateInToday(date) {
            when = "Today, " + date.formatted(date: .omitted, time: .shortened)
        } else if Calendar.current.isDateInYesterday(date) {
            when = "Yesterday, " + date.formatted(date: .omitted, time: .shortened)
        } else {
            when = date.formatted(date: .abbreviated, time: .shortened)
        }
        guard let summary = service.lastHistoryBackupSummary else { return "Last backup: \(when)" }
        let size = ByteCountFormatter.string(fromByteCount: Int64(summary.bytes), countStyle: .file)
        return "Last backup: \(when) · \(summary.messages) messages, \(size)"
    }
}

// MARK: - Privacy sub-page

struct PrivacySettingsView: View {
    let service: MessagingService
    @Environment(AppModel.self) private var model
    @AppStorage(PrivacyPreferences.incognitoKeyboardKey) private var incognitoKeyboard = true
    @AppStorage(PrivacyPreferences.sendTypingKey) private var sendTyping = true
    @AppStorage(PrivacyPreferences.linkPreviewsKey) private var linkPreviews = true
    @AppStorage(PrivacyPreferences.spotlightIndexingKey) private var spotlightIndexing = false
    @AppStorage(PrivacyPreferences.shareSuggestionsKey) private var shareSuggestions = false
    @AppStorage(ScamCheck.enabledKey) private var scamWarnings = true
    @State private var methods: SignInMethods?
    @State private var emailDiscoverable = UserDefaults.standard.bool(forKey: MessagingService.emailDiscoverableKey)
    @State private var phoneDiscoverable: Bool?
    @State private var discoverabilityError: String?

    var body: some View {
        List {
            Section {
                SettingsHero(systemName: "hand.raised.fill", color: .indigo, title: "Privacy",
                             message: "Choose who can find you and what others see. Your messages and calls are always end-to-end encrypted.")
                    .settingsBareRow()
            }
            if !service.isDemoAccount {
                Section {
                    LabeledContent {
                        Text("Always")
                    } label: {
                        HStack(spacing: 14) {
                            SettingsIcon(systemName: "at", color: .accentColor)
                            Text("Username")
                        }
                    }
                    if methods?.email == true {
                        discoverabilityToggle("Email", icon: "envelope.fill", isOn: emailDiscoverable) { on in
                            emailDiscoverable = on
                            try await service.setEmailDiscoverable(on)
                        } revert: { emailDiscoverable = $0 }
                    }
                    if let phoneDiscoverable {
                        discoverabilityToggle("Phone Number", icon: "phone.fill", isOn: phoneDiscoverable) { on in
                            self.phoneDiscoverable = on
                            try await service.setPhoneDiscoverable(on)
                        } revert: { self.phoneDiscoverable = $0 }
                    }
                } header: {
                    Text("Find Me By")
                } footer: {
                    Text(discoverabilityError ?? "Anyone with your username can message you. Turn these on so people who already have your email or number can find you too.")
                        .foregroundStyle(discoverabilityError == nil ? Color.secondary : Color.red)
                }
                .task {
                    methods = try? await service.apiClient.signInMethods()
                    if methods?.phone == true, let status = try? await service.phoneStatus() {
                        phoneDiscoverable = status.discoverable
                    }
                }
            }
            Section {
                NavigationLink(destination: ProxySettingsView()) {
                    HStack(spacing: 14) {
                        SettingsIcon(systemName: "network.badge.shield.half.filled", color: .blue)
                        Text("Proxy")
                        Spacer(minLength: 0)
                        Text(RelayProxy.isEnabled ? "On" : model.fallbackHost != nil ? "Backup" : "Off").foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                SettingsToggleRow(systemName: "ellipsis.bubble.fill", color: .blue, title: "Typing Indicators",
                                  isOn: $sendTyping)
                SettingsToggleRow(systemName: "checkmark.circle.fill", color: .blue, title: "Read Receipts",
                                  isOn: Binding(get: { service.sendReadReceipts }, set: { service.sendReadReceipts = $0 }))
            } header: {
                Text("Activity")
            } footer: {
                Text("Let people see when you're typing and when you've read their messages. With typing indicators off you still see theirs.")
            }

            Section("Messaging") {
                SettingsToggleRow(systemName: "timer", color: .orange, title: "Send Delay",
                                  info: "Waits a moment, a random amount, before each message goes out, so it's harder for someone watching internet traffic to tell when you're chatting.",
                                  isOn: Binding(get: { service.sendJitterEnabled }, set: { service.sendJitterEnabled = $0 }))
                SettingsToggleRow(systemName: "keyboard", color: .indigo, title: "Incognito Keyboard",
                                  info: "Asks your keyboard not to learn or remember what you type in Relay.",
                                  isOn: Binding(get: { incognitoKeyboard }, set: { incognitoKeyboard = $0 }))
                SettingsToggleRow(systemName: "exclamationmark.shield", color: .red, title: "Scam Warnings",
                                  info: "Relay checks incoming messages with links, money or code requests on your iPhone (with Apple Intelligence where available) and warns you if one looks like a scam. Nothing is sent anywhere, and nobody is reported unless you choose to.",
                                  isOn: $scamWarnings)
                SettingsToggleRow(systemName: "link", color: .teal, title: "Generate Link Previews",
                                  info: "Shows a preview of links you type. To make it, your iPhone visits the website (or YouTube for videos), which sees your IP address, even if you don't send the link. Relay never sees the link. Links you receive never load a preview, and previews are off while a proxy or backup connection is in use.",
                                  isOn: $linkPreviews)
            }

            Section {
                SettingsToggleRow(systemName: "magnifyingglass", color: .gray, title: "Show Chats in Search",
                                  isOn: Binding(get: { spotlightIndexing }, set: { enabled in
                                      spotlightIndexing = enabled
                                      if enabled { service.refreshConversations() }  // re-index now
                                      else { SpotlightIndexer.deindexAll() }
                                  }))
                SettingsToggleRow(systemName: "square.and.arrow.up", color: .gray, title: "Suggest Chats in Share Sheet",
                                  isOn: Binding(get: { shareSuggestions }, set: { enabled in
                                      shareSuggestions = enabled
                                      if !enabled { INInteraction.deleteAll(completion: nil) }
                                  }))
            } header: {
                Text("System Integration")
            } footer: {
                Text("Lets iOS show your chats in Search, the Share Sheet and Siri. iOS keeps these, with chat names and photos, outside Relay's encryption. Hidden chats are never included.")
            }

        }
        .modifier(ThemedPageBackground())
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func discoverabilityToggle(
        _ title: String, icon: String, isOn: Bool,
        set: @escaping (Bool) async throws -> Void, revert: @escaping (Bool) -> Void
    ) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { on in
            discoverabilityError = nil
            Task {
                do { try await set(on) } catch {
                    revert(!on)
                    discoverabilityError = FriendlyError.message(for: error)
                }
            }
        })) {
            HStack(spacing: 14) {
                SettingsIcon(systemName: icon, color: .accentColor)
                Text(title)
            }
        }
    }
}

// MARK: - Notifications sub-page

private struct NotificationSettingsView: View {
    let service: MessagingService
    @State private var notificationPrivacy: String = NotificationPreviewSetting.current.rawValue
    /// Kept here so the cards redraw: the service reads it from UserDefaults.
    @State private var instantDelivery = true

    var body: some View {
        List {
            Section {
                SettingsHero(systemName: "bell.badge.fill", color: .red, title: "Notifications",
                             message: "Your Lock Screen and alerts.")
                    .settingsBareRow()
            }
            Section {
                HStack(spacing: 10) {
                    ForEach(NotificationPreviewSetting.allCases, id: \.self) { level in
                        LockScreenPreviewCard(level: level, isSelected: notificationPrivacy == level.rawValue) {
                            notificationPrivacy = level.rawValue
                        }
                    }
                }
                .settingsBareRow()
            } header: {
                Text("Lock Screen Preview")
            }

            Section {
                HStack(spacing: 10) {
                    DeliveryModeCard(instant: true, isSelected: instantDelivery) {
                        instantDelivery = true
                        service.pushIncludeContent = true
                    }
                    DeliveryModeCard(instant: false, isSelected: !instantDelivery) {
                        instantDelivery = false
                        service.pushIncludeContent = false
                    }
                }
                .settingsBareRow()
            } header: {
                Text("Delivery")
            }
        }
        .modifier(ThemedPageBackground())
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: notificationPrivacy) { _, value in
            UserDefaults(suiteName: AppModel.appGroupId)?.set(value, forKey: "relay.notificationPrivacy")
        }
        .onAppear { instantDelivery = service.pushIncludeContent }
    }
}

// MARK: - Notification option cards

/// A small iPhone Lock Screen: wallpaper, date and time, and whatever
/// notifications sit under them.
struct MiniLockScreen<Content: View>: View {
    let isSelected: Bool
    var height: CGFloat = 112
    @ViewBuilder let content: Content

    @Environment(ChatAppearance.self) private var environmentAppearance
    /// The chat theme's colour, so the little Lock Screens match the theme
    /// around them.
    private var tint: Color { (ChatAppearance.app ?? environmentAppearance).bubbleTint }
    private var night: Color { Color(red: 0.05, green: 0.05, blue: 0.12) }

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [tint.mix(with: night, by: 0.7), tint.mix(with: night, by: 0.35),
                         tint.mix(with: .white, by: 0.12)],
                startPoint: .top, endPoint: .bottom)
            VStack(spacing: 0) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.system(size: 6.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.top, 9)
                Text("9:41")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.bottom, 6)
                VStack(spacing: 4) { content }
                    .padding(.horizontal, 5)
            }
        }
        .frame(height: height)
        .clipShape(.rect(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isSelected ? Color.white : Color.white.opacity(0.1),
                              lineWidth: isSelected ? 3 : 1)
        }
        .shadow(color: isSelected ? tint.opacity(0.5) : .clear, radius: 10)
        .environment(\.colorScheme, .dark)
    }
}

/// A notification banner as iOS draws it, shrunk to fit a card: frosted
/// glass, the sender's picture with Relay's icon in the corner (or just the
/// icon when the name is hidden), title, time and text.
struct MiniBanner: View {
    let sender: String?
    let text: String
    var time = "now"

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                if let sender {
                    Circle()
                        .fill(LinearGradient(colors: [Color(white: 0.66), Color(white: 0.48)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay {
                            Text(String(sender.prefix(1)))
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 17, height: 17)
                    appIcon(size: 8, radius: 2)
                        .offset(x: 2, y: 2)
                } else {
                    appIcon(size: 17, radius: 4)
                }
            }
            VStack(alignment: .leading, spacing: 0.5) {
                HStack(spacing: 2) {
                    Text(sender ?? "Relay").font(.system(size: 7.5, weight: .semibold))
                    Spacer(minLength: 0)
                    Text(time).font(.system(size: 6)).foregroundStyle(.secondary)
                }
                Text(text).font(.system(size: 7)).lineLimit(1)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 9, style: .continuous))
    }

    private func appIcon(size: CGFloat, radius: CGFloat) -> some View {
        Image(CurrentAppIcon.previewAsset)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: radius, style: .continuous))
    }
}

/// A notification that hasn't been filled in yet: what a content-free wake
/// carries.
private struct EmptyBanner: View {
    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(.white.opacity(0.25))
                .frame(width: 17, height: 17)
            VStack(alignment: .leading, spacing: 3) {
                Capsule().fill(.white.opacity(0.25)).frame(width: 26, height: 4)
                Capsule().fill(.white.opacity(0.18)).frame(width: 40, height: 4)
            }
            Spacer(minLength: 0)
        }
        .padding(5)
        .background(.ultraThinMaterial.opacity(0.6), in: .rect(cornerRadius: 9, style: .continuous))
    }
}

/// One Lock Screen Preview level, shown as the banner it produces.
struct LockScreenPreviewCard: View {
    let level: NotificationPreviewSetting
    let isSelected: Bool
    let onTap: () -> Void

    private var title: String {
        switch level {
        case .full: "Name & Message"
        case .nameOnly: "Name Only"
        case .none: "Hidden"
        }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                MiniLockScreen(isSelected: isSelected) {
                    MiniBanner(sender: level.showsSenderName ? "Alex" : nil,
                               text: level.showsContent ? "See you at 6?" : "New Message")
                }
                Text(title)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Lock Screen preview: \(title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// How a message reaches the iPhone. Instant: the banner arrives with the
/// push. Wake only: an empty wake comes first, then the message, a moment
/// later, once the iPhone has fetched it.
private struct DeliveryModeCard: View {
    let instant: Bool
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                MiniLockScreen(isSelected: isSelected, height: 130) {
                    if instant {
                        MiniBanner(sender: "Alex", text: "See you at 6?")
                    } else {
                        EmptyBanner()
                        Image(systemName: "arrow.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                        MiniBanner(sender: "Alex", text: "See you at 6?", time: "2s")
                    }
                }
                Text(instant ? "Instant" : "Wake Only")
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(instant
            ? "Instant: the encrypted message comes inside the push"
            : "Wake only: the push carries nothing and your iPhone fetches the message")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - About sub-page

private struct AboutSettingsView: View {
    let appVersion: String

    var body: some View {
        List {
            Section {
                SettingsHero(systemName: "info.circle.fill", color: .gray, title: "About Relay",
                             message: "Relay \(appVersion). How your data is handled, and the software Relay is built on.")
                    .settingsBareRow()
            }
            Section {
                NavigationLink(destination: DataRetentionView()) {
                    HStack(spacing: 14) {
                        SettingsIcon(systemName: "doc.text.magnifyingglass", color: .gray)
                        Text("Data & Retention Policy")
                    }
                }
                Link(destination: LegalLinks.privacy) {
                    SettingsExternalRow(systemName: "lock.doc.fill", color: .blue, title: "Privacy Policy")
                }
                .tint(.primary)
                Link(destination: LegalLinks.terms) {
                    SettingsExternalRow(systemName: "doc.text.fill", title: "Terms of Service")
                }
                .tint(.primary)
                NavigationLink(destination: AcknowledgementsView()) {
                    SettingsNavRow(systemName: "heart.text.square.fill", color: .gray, title: "Acknowledgements")
                }
            }
        }
        .modifier(ThemedPageBackground())
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Data & Retention Policy

private struct DataRetentionView: View {
    var body: some View {
        List {
            Section {
                SettingsHero(systemName: "server.rack", color: .gray, title: "Data & Retention",
                             message: "What Relay's server can see, what it keeps, and for how long.")
                    .settingsBareRow()
            }
            Section {
                RetentionRow(
                    icon: "lock.fill", color: .green,
                    title: "Message Content",
                    detail: "Messages are end-to-end encrypted with the Signal Protocol. The server sees only opaque ciphertext and never decrypts content."
                )
                RetentionRow(
                    icon: "person.2.slash", color: .orange,
                    title: "Who You Talk To",
                    detail: "Sealed sender hides who sent each message from the server. Group names, members and messages are end-to-end encrypted — the server keeps no group records. Your address book is never uploaded."
                )
                RetentionRow(
                    icon: "key.slash", color: .orange,
                    title: "Private Keys",
                    detail: "Your identity key lives in the Keychain, protected by a key held in the Secure Enclave. Session (ratchet) keys live in the app's AES-256 encrypted database. Keys leave this device only end-to-end encrypted, and only to your own devices when you link a new one."
                )
                RetentionRow(
                    icon: "eye.slash.fill", color: .gray,
                    title: "Server Logs",
                    detail: "Relay's server logs redact credentials, tokens and account IDs, and never include request bodies or message content."
                )
            } header: {
                Text("What the Server Can't See")
            }

            Section {
                RetentionRow(
                    icon: "person.fill", color: .teal,
                    title: "Account",
                    detail: "Your username; your device list with a hashed password for each device; a hashed account password, if you set one; and push notification tokens so your devices can be woken. Kept for the lifetime of the account."
                )
                RetentionRow(
                    icon: "at", color: .blue,
                    title: "Email",
                    detail: "If you verified an email, the server keeps a keyed token derived from it (used for account recovery) — never the address itself. Letting people find you by email is off by default; only if you turn it on is a blinded lookup entry stored."
                )
                RetentionRow(
                    icon: "key.horizontal.fill", color: .yellow,
                    title: "Public Keys",
                    detail: "Your public identity key and prekeys, so people can start encrypted chats with you, plus your sealed-sender access key. One-time prekeys are deleted once used; signed and Kyber prekeys are replaced when they rotate."
                )
                RetentionRow(
                    icon: "envelope.fill", color: .blue,
                    title: "Offline Message Queue",
                    detail: "Encrypted envelopes waiting for an offline device are kept for up to 14 days, up to 500 envelopes per device, and up to 512 KiB each. Delivered envelopes are deleted as soon as your device acknowledges them."
                )
                RetentionRow(
                    icon: "paperclip", color: .purple,
                    title: "Attachments",
                    detail: "Encrypted attachment blobs are stored for 14 days, then deleted automatically. The server cannot decrypt attachment content."
                )
            } header: {
                Text("What the Server Stores")
            } footer: {
                Text("Signing out removes this device from your account. Emergency Wipe erases messages and keys on all your devices.")
            }

            Section {
                RetentionRow(
                    icon: "iphone.and.arrow.forward", color: .indigo,
                    title: "On-Device Storage",
                    detail: "Messages and media are kept indefinitely on your device in an AES-256-encrypted SQLCipher database until you delete them or sign out."
                )
                RetentionRow(
                    icon: "clock.arrow.2.circlepath", color: .red,
                    title: "Nuke / Remote Wipe",
                    detail: "The Emergency Wipe command cryptographically destroys the local database and session keys on every device. This is permanent and cannot be undone."
                )
            } header: {
                Text("On-Device Retention")
            }

            Section {
                RetentionRow(
                    icon: "network", color: .secondary,
                    title: "Network Metadata",
                    detail: "IP addresses, connection timing, and envelope sizes are visible to the relay server and any network between you and it. TLS encrypts data in transit; Protect IP Address in Calls hides your IP from the people you call."
                )
            } header: {
                Text("Metadata Limits")
            } footer: {
                Text("These retention rules are enforced directly by the Relay server and client code.")
                    .padding(.top, 4)
            }
        }
        .modifier(ThemedPageBackground())
        .navigationTitle("Data & Retention")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct RetentionRow: View {
    let icon: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            SettingsIcon(systemName: icon, color: color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Storage sub-page

private struct StorageSettingsView: View {
    let service: MessagingService
    @State private var cacheSize: Int64 = 0
    @State private var isClearing = false
    @State private var confirmingClear = false
    @State private var clearError: String?

    var body: some View {
        List {
            Section {
                SettingsHero(systemName: "internaldrive.fill", color: .gray, title: "Storage",
                             message: "What Relay keeps on this iPhone, and how to free up space.")
                    .settingsBareRow()
            }
            Section {
                LabeledContent("Cached Media", value: formattedSize(cacheSize))
                Button(role: .destructive) {
                    confirmingClear = true
                } label: {
                    HStack {
                        if isClearing { ProgressView().padding(.trailing, 4) }
                        Text("Clear Cached Media")
                    }
                }
                .disabled(cacheSize == 0 || isClearing)
            } header: {
                Text("Media Cache")
            } footer: {
                Text("Frees up space by removing photos, videos and files you've received. They download again when you open them, for about 2 weeks after they were sent.")
            }

            Section("On This iPhone") {
                LabeledContent("Messages", value: "Encrypted")
            }
        }
        .modifier(ThemedPageBackground())
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { cacheSize = attachmentCacheSize() }
        .confirmationDialog("Clear cached media?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear Cached Media", role: .destructive) { clearCache() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Photos, videos and files you've received are removed from this iPhone. They download again when you open them, but ones older than about 2 weeks are gone for good.")
        }
        .alert("Couldn't Clear Media", isPresented: Binding(
            get: { clearError != nil },
            set: { if !$0 { clearError = nil } }
        )) {
            Button("OK", role: .cancel) { clearError = nil }
        } message: {
            Text(clearError ?? "")
        }
    }

    private func attachmentCacheSize() -> Int64 {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppModel.appGroupId
        ) else { return 0 }
        let dir = container.appendingPathComponent("attachments")
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Goes through MessagingService so only re-downloadable blobs are removed
    /// and their rows reset to "not downloaded". Deleting the directory directly
    /// would destroy local-only Note to Self media and leave isDownloaded=true.
    private func clearCache() {
        isClearing = true
        Task {
            do {
                try await service.clearCachedMedia()
            } catch {
                clearError = FriendlyError.message(for: error)
            }
            cacheSize = attachmentCacheSize()
            isClearing = false
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}

// MARK: - Security sub-page

private struct SecuritySettingsView: View {
    let service: MessagingService
    @State private var panicMode = PanicModeManager.shared
    @State private var showingPanicSettings = false
    @AppStorage(AppSwitcherPrivacy.modeKey) private var appSwitcherMode = AppSwitcherPrivacy.Mode.content.rawValue
    @AppStorage("relay.screenLockEnabled") private var screenLockEnabled = false
    @AppStorage("relay.screenLockTimeout") private var screenLockTimeout = 60

    var body: some View {
        List {
            Section {
                SettingsHero(systemName: "lock.shield.fill", color: .teal, title: "Security",
                             message: "Lock Relay, hide chats, and see how your messages are protected.")
                    .settingsBareRow()
            }
            Section {
                SettingsToggleRow(systemName: "faceid", color: .green, title: "Screen Lock",
                                  isOn: $screenLockEnabled)
                if screenLockEnabled {
                    Picker(selection: $screenLockTimeout) {
                        Text("Immediately").tag(0)
                        Text("After 1 minute").tag(60)
                        Text("After 5 minutes").tag(300)
                        Text("After 15 minutes").tag(900)
                        Text("After 1 hour").tag(3600)
                    } label: {
                        HStack(spacing: 14) {
                            SettingsIcon(systemName: "timer", color: .green)
                            Text("Lock After")
                        }
                    }
                }
            } footer: {
                Text("Require \(biometricTypeName) when returning to Relay after it's been in the background.")
            }

            Section {
                Picker(selection: $appSwitcherMode) {
                    ForEach(AppSwitcherPrivacy.Mode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                } label: {
                    HStack(spacing: 14) {
                        SettingsIcon(systemName: "square.on.square", color: .indigo)
                        Text("Hide in App Switcher")
                    }
                }
                .pickerStyle(.navigationLink)
            } footer: {
                Text("Messages & Names blurs messages, names and photos and leaves the rest of the screen as it is.")
            }

            Section {
                SettingsToggleRow(systemName: "eye.slash.fill", color: .indigo, title: "Panic Mode",
                                  isOn: Binding(
                                    get: { panicMode.isEnabled },
                                    set: { enabled in
                                        if enabled { showingPanicSettings = true }
                                        else { panicMode.disable() }
                                    }))
                if panicMode.isEnabled {
                    Button("Configure Panic Mode") { showingPanicSettings = true }.tint(.primary)
                        .foregroundStyle(.tint)
                }
            } footer: {
                Text("Hides selected chats behind a PIN. Long-press a conversation in the list to mark it hidden.")
            }

            Section {
                NavigationLink(destination: PinLockSettingsView()) {
                    HStack(spacing: 14) {
                        SettingsIcon(systemName: "lock.shield.fill", color: .indigo)
                        LabeledContent("Relay PIN Lock", value: PinLockManager.shared.mode == .off ? "Off" : "On")
                    }
                }
            } footer: {
                Text("A PIN every time you come back to Relay, and a distress PIN that erases it.")
            }

            Section {
                HStack(spacing: 14) {
                    SettingsIcon(systemName: "lock.shield.fill", color: .green)
                    LabeledContent("Messages and Calls", value: "End-to-End")
                }
                HStack(spacing: 14) {
                    SettingsIcon(systemName: "iphone", color: .blue)
                    LabeledContent("On This Device", value: "Encrypted")
                }
                HStack(spacing: 14) {
                    SettingsIcon(systemName: "key.fill", color: .orange)
                    LabeledContent("Keys", value: "Secure Enclave")
                }
            } header: {
                Text("Encryption")
            } footer: {
                Text("Only you and the people you talk to can read your messages and hear your calls. Not even Relay can. On this iPhone, messages are stored encrypted, with the key guarded by the iPhone's built-in security chip (the Secure Enclave).")
            }
        }
        .modifier(ThemedPageBackground())
        .navigationTitle("Security")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showingPanicSettings) {
            PanicModeSheet(manager: panicMode)
        }
    }

    private var biometricTypeName: String { BiometricGate.biometryName }
}

// MARK: - Edit Profile Sheet

private struct EditProfileSheet: View {
    let service: MessagingService
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var displayNameDraft: String
    @State private var bioDraft: String
    @State private var linkDrafts: [ProfileLink]
    @State private var avatarData: Data?
    @State private var avatarChanged = false
    @State private var profilePhoto: PhotosPickerItem?
    @State private var photoToCrop: CropImageItem?
    @State private var loadingPhoto = false
    @State private var showingChangeUsername = false

    init(service: MessagingService, onDone: @escaping () -> Void) {
        self.service = service
        self.onDone = onDone
        _displayNameDraft = State(initialValue: service.myDisplayName ?? "")
        _avatarData = State(initialValue: service.myAvatarData)
        _bioDraft = State(initialValue: UserDefaults.standard.string(forKey: "my.profile.bio") ?? "")
        _linkDrafts = State(initialValue: service.myLinks)
    }

    private static let maxLinks = 5

    private var previewName: String {
        displayNameDraft.isEmpty ? (service.username ?? "?") : displayNameDraft
    }

    var body: some View {
        Group {
            Form {
                Section {
                    HStack {
                        Spacer()
                        PhotosPicker(selection: $profilePhoto, matching: .images) {
                            ZStack(alignment: .bottomTrailing) {
                                AvatarView(name: previewName, size: 90, imageData: avatarData)
                                AvatarEditBadge(systemImage: "camera.fill", diameter: 26)
                                    .offset(x: 3, y: 3)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                Section {
                    TextField("Display name", text: $displayNameDraft)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                    Button { showingChangeUsername = true } label: {
                        HStack {
                            Text("Username").foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            if let username = service.username {
                                Text("@\(username)").foregroundStyle(.secondary)
                            }
                            if !service.isDemoAccount {
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .tint(.primary)
                    .disabled(service.isDemoAccount) // demo login is fixed
                } header: {
                    Text("Name")
                } footer: {
                    if ReservedNames.isReserved(displayNameDraft) {
                        Text("That display name is reserved. Please choose another.")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    ZStack(alignment: .topLeading) {
                        if bioDraft.isEmpty {
                            Text("Write something about yourself…")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                        }
                        TextEditor(text: $bioDraft)
                            .frame(minHeight: 80)
                    }
                } header: {
                    Text("Bio")
                } footer: {
                    Text("Shown on your profile card. End-to-end encrypted.")
                }

                Section {
                    ForEach($linkDrafts) { $link in
                        VStack(spacing: 4) {
                            TextField("Label (e.g. Website)", text: $link.label)
                                .font(.subheadline.weight(.medium))
                                .autocorrectionDisabled()
                            TextField("https://…", text: $link.url)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                        }
                    }
                    .onDelete { linkDrafts.remove(atOffsets: $0) }
                    if linkDrafts.count < Self.maxLinks {
                        Button {
                            linkDrafts.append(ProfileLink())
                        } label: {
                            Label("Add Link", systemImage: "plus.circle.fill")
                        }
                    }
                } header: {
                    Text("Links")
                } footer: {
                    Text("Up to \(Self.maxLinks). Shown on your profile card. End-to-end encrypted.")
                }

                if avatarData != nil {
                    Section {
                        Button("Remove Photo", role: .destructive) { setAvatar(nil) }
                    }
                }
            }
            .modifier(ThemedPageBackground())
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if loadingPhoto {
                        ProgressView()
                    } else {
                        Button("Save") { saveAndDismiss() }.bold()
                            .disabled(ReservedNames.isReserved(displayNameDraft))
                    }
                }
            }
            .onChange(of: profilePhoto) { _, item in loadPhoto(item) }
            .fullScreenCover(item: $photoToCrop) { item in
                AvatarCropView(image: item.image) {
                    photoToCrop = nil
                    profilePhoto = nil
                } onChoose: { cropped in
                    if let jpeg = cropped.avatarJPEG() { setAvatar(jpeg) }
                    photoToCrop = nil
                    profilePhoto = nil
                }
            }
            .navigationDestination(isPresented: $showingChangeUsername) {
                ChangeUsernameSheet(currentUsername: service.username ?? "")
            }
        }
    }

    private func saveAndDismiss() {
        service.setMyDisplayName(displayNameDraft)
        // The avatar is distributed to peers, so only commit it if it changed.
        if avatarChanged {
            service.setMyAvatarData(avatarData)
        }
        // Sent to peers over the E2EE profile channel; the revision only bumps if
        // something changed.
        service.setMyProfileText(status: "", bio: bioDraft, links: linkDrafts)
        onDone()
        dismiss()
    }

    // Held locally until Save.
    private func setAvatar(_ data: Data?) {
        avatarData = data
        avatarChanged = true
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        loadingPhoto = true
        Task {
            defer { loadingPhoto = false }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = SafeImage.image(from: data, maxPixelSize: 3000) else { return }
            photoToCrop = CropImageItem(image: image)
        }
    }
}

// MARK: - Settings icon

/// A settings row's icon: a white symbol on a tile of the row's colour.
struct SettingsIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(color.gradient, in: .rect(cornerRadius: 7))
    }
}

/// The top of a settings page about one thing (recovery key, passkeys,
/// linked devices…): a large tile in the page's colour, a title and what it's
/// for. Sits in a List section with a clear background.
struct SettingsHero: View {
    let systemName: String
    let color: Color
    var title: String? = nil
    let message: String
    /// While the big title is on screen the bar's small one is hidden, as in
    /// iOS Settings, so the page doesn't name itself twice.
    @State private var titleOnScreen = true

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemName)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(color.gradient, in: .rect(cornerRadius: 16))
                .accessibilityHidden(true)
            if let title {
                Text(title)
                    .font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                    .onScrollVisibilityChange(threshold: 0.2) { titleOnScreen = $0 }
            }
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .toolbar {
            if title != nil, titleOnScreen {
                // A blank principal item stands in for the bar title.
                ToolbarItem(placement: .principal) { Text(verbatim: " ") }
            }
        }
    }
}

/// The page's main action, as a full-width capsule in its colour.
struct SettingsPrimaryButton: View {
    let title: String
    var systemName: String? = nil
    let color: Color
    var working = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if working {
                    ProgressView().tint(.white)
                } else {
                    if let systemName { Image(systemName: systemName) }
                    Text(title)
                }
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(color.gradient, in: .capsule)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(working)
    }
}

/// A list row holding a SettingsHero or SettingsPrimaryButton: no card behind
/// it and no separator.
extension View {
    func settingsBareRow() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
    }
}

struct SettingsNavRow: View {
    let systemName: String
    let color: Color
    let title: String

    var body: some View {
        HStack(spacing: 14) {
            SettingsIcon(systemName: systemName, color: color)
            Text(title)
        }
    }
}

/// Small ⓘ button that shows an explanation in an alert. Owns its own
/// presentation so any settings row can add one without shared state.
struct SettingsInfoButton: View {
    let title: String
    let message: String
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Image(systemName: "info.circle")
                .font(.footnote)
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About \(title)")
        .alert(title, isPresented: $showing) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}

/// Standard settings toggle row: icon, title, optional ⓘ, trailing
/// switch.
struct SettingsToggleRow: View {
    let systemName: String
    var color: Color = .gray
    let title: String
    var info: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 14) {
            SettingsIcon(systemName: systemName, color: color)
            Text(title)
            if let info {
                SettingsInfoButton(title: title, message: info)
            }
            Spacer(minLength: 8)
            // Real title (hidden visually) so VoiceOver announces the switch.
            Toggle(title, isOn: $isOn)
                .labelsHidden()
        }
    }
}


// MARK: - AvatarView

struct AvatarView: View {
    let name: String
    var size: CGFloat = 44
    var imageData: Data? = nil

    var body: some View {
        Group {
            if let imageData, let ui = DecodedImageCache.image(for: imageData) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(avatarColor.gradient)
                    .overlay {
                        Text(initial)
                            .font(.system(size: size * 0.42, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
    }

    private var initial: String {
        name.first.map { String($0).uppercased() } ?? "?"
    }

    private var avatarColor: Color { Self.color(for: name) }

    /// A person's colour, from their name: the same on their avatar and on
    /// their name in group chats.
    static func color(for name: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green]
        var hash = 0
        for scalar in name.unicodeScalars { hash = (hash &* 31 &+ Int(scalar.value)) }
        return palette[Int(hash.magnitude % UInt(palette.count))]
    }
}

// MARK: - PanicModeSheet

struct PanicModeSheet: View {
    let manager: PanicModeManager

    @State private var showingPINSetup = false

    var body: some View {
        Group {
            Form {
                Section {
                    SettingsHero(systemName: "eye.slash.fill", color: .indigo,
                                 message: "Hide chats behind a PIN. Long-press a chat in the list to hide it; the lock icon in the Chats header shows hidden chats again.")
                        .settingsBareRow()
                }
                Section {
                    SettingsToggleRow(systemName: "eye.slash.fill", color: .indigo, title: "Panic Mode", isOn: Binding(
                        get: { manager.isEnabled },
                        set: { enabled in
                            if enabled { showingPINSetup = true }
                            else { manager.disable() }
                        }
                    ))
                    if manager.isEnabled {
                        Button { showingPINSetup = true } label: {
                            SettingsNavRow(systemName: "pencil", color: .gray, title: "Change PIN")
                        }
                        .tint(.primary)
                        HStack(spacing: 14) {
                            SettingsIcon(systemName: "bubble.left.and.bubble.right.fill", color: .blue)
                            LabeledContent("Hidden Chats", value: "\(manager.hiddenIds.count)")
                        }
                    }
                }
            }
            .modifier(ThemedPageBackground())
            .navigationTitle("Panic Mode")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showingPINSetup) {
                PanicSetupSheet(manager: manager)
            }
        }
    }
}

// MARK: - PanicSetupSheet

struct PanicSetupSheet: View {
    let manager: PanicModeManager

    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var confirm = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                SettingsHero(systemName: "circle.grid.3x3.fill", color: .indigo, title: "Choose a PIN",
                             message: "You'll enter it to see hidden chats. Use at least 4 digits.")
                    .settingsBareRow()
            }
            Section {
                SecureField("PIN", text: $pin)
                    .keyboardType(.numberPad)
                    .focused($focused)
                SecureField("Confirm PIN", text: $confirm)
                    .keyboardType(.numberPad)
            } footer: {
                Text(error ?? "Relay doesn't keep the PIN itself, so it can't show it to you. If you forget it, turn Panic Mode off here and set a new one.")
                    .foregroundStyle(error == nil ? Color.secondary : Color.red)
            }
            Section {
                SettingsPrimaryButton(title: "Save PIN", color: .indigo) { save() }
                    .disabled(pin.count < 4 || confirm.isEmpty)
                    .settingsBareRow()
            }
        }
        .modifier(ThemedPageBackground())
        .navigationTitle("Panic PIN")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
    }

    private func save() {
        guard pin.count >= 4 else { error = "Use at least 4 digits."; return }
        guard pin.allSatisfy({ $0.isASCII && $0.isNumber }) else { error = "Use digits only."; return }
        guard pin == confirm else { error = "The two PINs don't match."; return }
        let chosen = pin
        Task {
            await manager.enableAsync(pin: chosen)
            dismiss()
        }
    }
}

extension UIImage {
    func avatarJPEG(maxDimension: CGFloat = 256, quality: CGFloat = 0.8) -> Data? {
        let longest = max(size.width, size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: quality)
    }
}

// MARK: - Change Username Sheet

private struct ChangeUsernameSheet: View {
    let currentUsername: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var usernameStatus: UsernameStatus = .idle
    @State private var checkTask: Task<Void, Never>?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    enum UsernameStatus: Equatable {
        case idle, checking, available, taken, unknown, invalid(String), unchanged
    }

    private var canSave: Bool {
        guard !isLoading else { return false }
        if case .available = usernameStatus { return true }
        return false
    }

    private var trimmed: String { username.lowercased() }

    var body: some View {
        Group {
            Form {
                Section {
                    SettingsHero(systemName: "at", color: .pink, title: "Your Username",
                                 message: "People find you by your username, your link or your QR code. No phone number or email needed.")
                        .settingsBareRow()
                }
                Section {
                    HStack {
                        Text("@").foregroundStyle(.secondary)
                        TextField("username", text: $username)
                            .focused($isFocused)
                            .keyboardType(.asciiCapable)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit { isFocused = false }
                            .onChange(of: username) { _, new in scheduleCheck(new) }
                        statusIcon
                    }
                } footer: {
                    statusMessage.padding(.top, 2)
                }

                Section {
                    HStack {
                        Text("Link")
                        Spacer(minLength: 0)
                        Text("relaymsg.app/add/\(trimmed.isEmpty ? currentUsername : trimmed)")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Section {
                    SettingsPrimaryButton(title: "Save Username", color: .pink, working: isLoading) { save() }
                        .disabled(!canSave)
                        .settingsBareRow()
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .modifier(ThemedPageBackground())
            .navigationTitle("Username")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                username = currentUsername
                isFocused = true
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch usernameStatus {
        case .idle, .unchanged: EmptyView()
        case .checking:   ProgressView().scaleEffect(0.75)
        case .available:  Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .unknown:    Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
        case .taken, .invalid: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        switch usernameStatus {
        case .idle:
            Text(UsernameRules.hint)
        case .unchanged:
            Text("This is already your username.")
        case .checking:
            Text("Checking availability…")
        case .available:
            Text("@\(trimmed) is available").foregroundStyle(.green)
        case .taken:
            Text("@\(trimmed) is already taken").foregroundStyle(.red)
        case .unknown:
            Text("Couldn't check — you're offline").foregroundStyle(.orange)
        case .invalid(let reason):
            Text(reason).foregroundStyle(.orange)
        }
    }

    private func scheduleCheck(_ raw: String) {
        let lower = raw.lowercased()
        if lower != raw { username = lower; return }
        checkTask?.cancel()
        guard !lower.isEmpty else { usernameStatus = .idle; return }
        if lower == currentUsername { usernameStatus = .unchanged; return }
        if let reason = UsernameRules.validationError(lower) { usernameStatus = .invalid(reason); return }
        usernameStatus = .checking
        checkTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let availability = await model.checkUsername(lower)
            guard !Task.isCancelled else { return }
            switch availability {
            case .available: usernameStatus = .available
            case .taken:     usernameStatus = .taken
            case .unknown:   usernameStatus = .unknown
            }
        }
    }

    private func save() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                try await model.changeUsername(username)
                dismiss()
            } catch {
                errorMessage = FriendlyError.message(for: error)
            }
            isLoading = false
        }
    }
}

// MARK: - Invite share sheet

struct InviteShareSheet: UIViewControllerRepresentable {
    let username: String?

    private var items: [Any] {
        var message = "Hey! I'm using Relay, an end-to-end encrypted messenger. Relay can't read our messages or see who we talk to, and there are no ads or tracking."
        if let name = username, !name.isEmpty {
            message += " Add me at https://relaymsg.app/add/\(name)"
        } else {
            message += " Join me, download the app and add me."
        }
        return [message]
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - About rows

/// A settings row that opens something outside the app (Safari / Mail).
struct SettingsExternalRow: View {
    let systemName: String
    var color: Color = .accentColor
    let title: String

    var body: some View {
        HStack(spacing: 14) {
            SettingsIcon(systemName: systemName, color: color)
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }
}

/// Open-source components shipped in the app and their licences.
struct AcknowledgementsView: View {
    private struct Component: Identifiable {
        let name: String
        let license: String
        let url: String
        let note: String
        var id: String { name }
    }

    private let components: [Component] = [
        Component(name: "libsignal", license: "AGPL-3.0",
                  url: "https://github.com/signalapp/libsignal",
                  note: "Signal Protocol (PQXDH, Double Ratchet), sealed sender and safety numbers. © Signal Messenger, LLC."),
        Component(name: "SQLCipher", license: "BSD-3-Clause",
                  url: "https://github.com/sqlcipher/sqlcipher",
                  note: "Encrypted on-device database. © Zetetic LLC. Packaged via skiptools/swift-sqlcipher; includes SQLite (public domain)."),
        Component(name: "swift-protobuf", license: "Apache-2.0",
                  url: "https://github.com/apple/swift-protobuf",
                  note: "Protocol Buffers runtime. © Apple Inc."),
        Component(name: "swift-sodium / libsodium", license: "ISC",
                  url: "https://github.com/jedisct1/swift-sodium",
                  note: "Cryptographic primitives. © Frank Denis."),
        Component(name: "WebRTC", license: "BSD-3-Clause",
                  url: "https://github.com/stasel/WebRTC",
                  note: "Voice and video calls. © The WebRTC project authors (Google). Binary distribution by stasel/WebRTC."),
    ]

    var body: some View {
        List {
            Section {
                SettingsHero(systemName: "heart.text.square.fill", color: .gray, title: "Acknowledgements",
                             message: "Relay is built on open-source software. Thank you to the people who make it.")
                    .settingsBareRow()
            }
            Section {
                ForEach(components) { c in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(c.name).font(.headline)
                            Spacer(minLength: 8)
                            Text(c.license)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Text(c.note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let url = URL(string: c.url) {
                            Link(c.url, destination: url)
                                .font(.caption)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } footer: {
                Text("Relay is built on these open-source projects and their dependencies. Full licence texts are available at the linked repositories.")
            }
        }
        .modifier(ThemedPageBackground())
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Delete account

/// Permanent account deletion (App Review 5.1.1(v)). Requires typing DELETE,
/// deletes the account on the relay, then wipes this device.
private struct DeleteAccountSheet: View {
    let service: MessagingService
    let onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""
    @State private var isDeleting = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    private var confirmed: Bool {
        confirmation.trimmingCharacters(in: .whitespaces) == "DELETE"
    }

    var body: some View {
        Group {
            Form {
                Section {
                    SettingsHero(systemName: service.isDemoAccount ? "arrow.counterclockwise" : "person.crop.circle.badge.xmark",
                                 color: service.isDemoAccount ? .orange : .red,
                                 message: service.isDemoAccount
                                    ? "This is a demo account, so it's reset instead of deleted."
                                    : "This permanently deletes your Relay account. It can't be undone.")
                        .settingsBareRow()
                }
                Section {
                    if service.isDemoAccount {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("• Its devices are signed out and its keys and undelivered messages are removed from the server.")
                            Text("• All messages and media on this iPhone are erased.")
                            Text("• The same review sign-in works again afterwards.")
                            Text("• A normal account is deleted permanently, its username released.")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("• Your username is released and people can no longer reach you.")
                        Text("• All your linked devices are signed out and removed.")
                        Text("• Undelivered messages, keys and your profile are deleted from the server.")
                        Text("• All messages and media on this iPhone are erased.")
                        Text("• Messages you've already sent stay on the other person's phone.")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField("DELETE", text: $confirmation)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .disabled(isDeleting)
                } header: {
                    Text("Type DELETE to confirm")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red).font(.footnote)
                    }
                }

                Section {
                    SettingsPrimaryButton(title: service.isDemoAccount ? "Reset Demo Account" : "Delete Account Permanently",
                                          systemName: service.isDemoAccount ? "arrow.counterclockwise" : "trash.fill",
                                          color: .red, working: isDeleting) {
                        delete()
                    }
                    .disabled(!confirmed)
                    .settingsBareRow()
                }
            }
            .navigationTitle(service.isDemoAccount ? "Reset Demo Account" : "Delete Account")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(isDeleting)
            .onAppear { focused = true }
        }
    }

    private func delete() {
        guard confirmed else { return }
        focused = false
        isDeleting = true
        errorMessage = nil
        Task {
            do {
                // Sign in with Apple accounts need a fresh code so the relay can revoke
                // the Apple token. Cancelling still deletes.
                let appleCode = AppleSignInRecord.used ? await AppleReauthorization.authorizationCode() : nil
                try await service.deleteAccount(appleAuthorizationCode: appleCode)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
                onDeleted()
            } catch {
                errorMessage = "Couldn't delete your account: \(FriendlyError.message(for: error)) Nothing was deleted — please try again."
                isDeleting = false
            }
        }
    }
}

/// The relay emails a code to the new address, then re-keys its
/// email lookup (recovery and find-by-email).
private struct ChangeEmailSheet: View {
    /// Removing the email needs a passkey to confirm with.
    let canRemove: Bool
    let onRemoved: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showingRemove = false
    @State private var showingAddPasskeyFirst = false
    @State private var newEmail = ""
    @State private var codeSent = false
    @State private var code = ""
    @State private var working = false
    @State private var errorMessage: String?

    private var normalizedEmail: String { newEmail.lowercased().trimmingCharacters(in: .whitespaces) }

    var body: some View {
        Group {
            Form {
                Section {
                    SettingsHero(systemName: codeSent ? "envelope.open.fill" : "envelope.fill", color: .blue,
                                 title: codeSent ? "Check Your Email" : "Change Email",
                                 message: codeSent
                                    ? "We sent a code to \(normalizedEmail)."
                                    : "Your email signs you in and, if you turn it on in Privacy, lets people find you.")
                        .settingsBareRow()
                }
                if !codeSent {
                    Section {
                        TextField("New email address", text: $newEmail)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } footer: {
                        footer("We'll send a code to the new address to check it's yours.")
                    }
                    Section {
                        SettingsPrimaryButton(title: "Send Code", color: .blue, working: working) { sendCode() }
                            .disabled(!normalizedEmail.contains("@"))
                            .settingsBareRow()
                    }
                } else {
                    Section {
                        TextField("Code", text: $code)
                            .textContentType(.oneTimeCode)
                            .keyboardType(.numberPad)
                            .onChange(of: code) { _, new in
                                let digits = String(new.filter(\.isNumber).prefix(10))
                                if digits != new { code = digits }
                            }
                    } footer: {
                        footer("Enter the code from the email.")
                    }
                    Section {
                        SettingsPrimaryButton(title: "Confirm", color: .blue, working: working) { confirm() }
                            .disabled((6...10).contains(code.count) == false)
                            .settingsBareRow()
                        Button("Send a New Code") { sendCode() }
                            .disabled(working)
                            .tint(.primary)
                            .frame(maxWidth: .infinity)
                            .settingsBareRow()
                    }
                }
                if !codeSent {
                    Section {
                        Button("Remove Email", role: .destructive) {
                            if canRemove { showingRemove = true } else { showingAddPasskeyFirst = true }
                        }
                    } footer: {
                        Text("Signing in with your email, Apple or Google stops working. Your phone number, passkeys and recovery key still do.")
                    }
                }
            }
            .modifier(ThemedPageBackground())
            .navigationTitle("Email")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(working)
            .navigationDestination(isPresented: $showingRemove) {
                RemoveEmailSheet {
                    onRemoved()
                    dismiss()
                }
            }
            .alert("Add a Passkey First", isPresented: $showingAddPasskeyFirst) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Removing your email is confirmed with a passkey. Create one in Passkeys, then come back.")
            }
        }
    }

    private func footer(_ text: String) -> some View {
        Text(errorMessage ?? text)
            .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
    }

    private func sendCode() {
        working = true
        errorMessage = nil
        Task {
            do {
                try await model.requestEmailChange(to: normalizedEmail)
                codeSent = true
            } catch {
                errorMessage = FriendlyError.message(for: error)
            }
            working = false
        }
    }

    private func confirm() {
        working = true
        errorMessage = nil
        Task {
            do {
                try await model.confirmEmailChange(newEmail: normalizedEmail, code: code)
                dismiss()
            } catch {
                errorMessage = FriendlyError.message(for: error)
            }
            working = false
        }
    }
}

private extension View {
    /// Records this page as the open one while it's on screen (and through
    /// pages opened from it, until another takes its place).
    func markOpen(_ page: String, in openPage: Binding<String?>) -> some View {
        onAppear { openPage.wrappedValue = page }
    }
}
