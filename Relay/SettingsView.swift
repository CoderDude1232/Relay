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
                                Text(displayName)
                                    .font(.title3.bold())
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
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
                                SettingsIcon(systemName: "qrcode", color: .accentColor)
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
                            SettingsNavRow(systemName: "person.crop.circle.fill", color: .accentColor, title: "Account")
                        }
                        .listRowBackground(rowHighlight("account"))
                    }
                    NavigationLink(destination: AppearanceSettingsView().markOpen("appearance", in: $openPage)) {
                        SettingsNavRow(systemName: "paintbrush.fill", color: .accentColor, title: "Appearance")
                    }
                    .listRowBackground(rowHighlight("appearance"))
                    NavigationLink(destination: ChatsSettingsView(service: service).markOpen("chats", in: $openPage)) {
                        SettingsNavRow(systemName: "bubble.left.and.bubble.right.fill", color: .accentColor, title: "Chats")
                    }
                    .listRowBackground(rowHighlight("chats"))
                    NavigationLink(destination: PrivacySettingsView(service: service).markOpen("privacy", in: $openPage)) {
                        SettingsNavRow(systemName: "hand.raised.fill", color: .accentColor, title: "Privacy")
                    }
                    .listRowBackground(rowHighlight("privacy"))
                    NavigationLink(destination: SecuritySettingsView(service: service).markOpen("security", in: $openPage)) {
                        SettingsNavRow(systemName: "lock.shield.fill", color: .accentColor, title: "Security")
                    }
                    .listRowBackground(rowHighlight("security"))
                    NavigationLink(destination: DataStorageSettingsView(service: service).markOpen("data", in: $openPage)) {
                        SettingsNavRow(systemName: "internaldrive.fill", color: .accentColor, title: "Data & Storage")
                    }
                    .listRowBackground(rowHighlight("data"))
                }

                // MARK: Invite (hidden on demo accounts, which can't reach real users)
                if !service.isDemoAccount {
                Section {
                    Button {
                        showingInvite = true
                    } label: {
                        HStack(spacing: 14) {
                            SettingsIcon(systemName: "person.badge.plus", color: .accentColor)
                            Text("Invite Friends").foregroundStyle(.primary)
                        }
                    }
                    .tint(.primary)
                    .sheet(isPresented: $showingInvite) {
                        InviteShareSheet(username: service.username)
                            .ignoresSafeArea()
                    }
                }
                }

                // MARK: Support
                // Privacy Policy, Terms and Acknowledgements live under Privacy.
                Section {
                    Link(destination: LegalLinks.feedbackMail) {
                        SettingsExternalRow(systemName: "envelope.fill", title: "Send Feedback")
                    }
                }

                // MARK: Sign out
                Section {
                    Button(role: .destructive) {
                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                        confirmingSignOut = true
                    } label: {
                        HStack(spacing: 14) {
                            SettingsIcon(systemName: "rectangle.portrait.and.arrow.right", color: .red, useColor: true)
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
                             ? "Your account stays active, so you can sign back in anytime. Chats are removed from this device and come back from your encrypted backup when you sign back in."
                             : "Your account stays active, so you can sign back in anytime. Chats are removed from this device and can't be brought back, because message history backup is off. Turn it on in Data & Storage first to keep them.")
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
        ("Chat Folders", "folders labels organise", .folders),
        ("Scheduled Messages", "schedule later send", .scheduled),
        ("Blocked Contacts", "block blocked unblock", .blocked),
        ("Read Receipts", "read receipts seen blue ticks", .privacy),
        ("Typing Indicators", "typing", .privacy),
        ("Link Previews", "link preview", .privacy),
        ("Incognito Keyboard", "keyboard autocorrect learning", .privacy),
        ("Notification Previews", "notifications lock screen preview banner", .privacy),
        ("Relay-Only Calls", "calls ip address relay turn direct", .privacy),
        ("Scam Warnings", "scam fraud warning", .privacy),
        ("Send Delay", "delay timing jitter", .privacy),
        ("Proxy", "proxy blocked censorship connect", .proxy),
        ("Data & Retention", "retention server stores policy legal", .privacy),
        ("Screen Lock", "lock face id touch id passcode", .security),
        ("Panic Mode", "panic hide chats pin", .security),
        ("Message History Backup", "backup history restore", .data),
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
    @State private var showingEmailSheet = false
    @State private var showingQR = false
    @State private var linkCopied = false
    @State private var showingPasswordSheet = false
    @State private var emailDiscoverable = UserDefaults.standard.bool(forKey: MessagingService.emailDiscoverableKey)
    @State private var discoverabilityError: String?
    @State private var showingDeleteAccount = false
    @State private var confirmingNuke = false
    @State private var nukeInProgress = false
    @State private var nukeSucceeded = false
    @State private var nukeError: String?
    @State private var methods: SignInMethods?
    @State private var showingRemoveEmail = false
    @State private var showingAddPasskeyFirst = false

    private var username: String { service.username ?? "" }
    private var addLink: String { "relaymsg.app/add/\(username)" }
    /// Assume an email until the relay says otherwise.
    private var hasEmail: Bool { methods?.email ?? true }

    var body: some View {
        List {
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
                    if hasEmail {
                        Button { showingEmailSheet = true } label: {
                            HStack(spacing: 14) {
                                SettingsIcon(systemName: "envelope.fill", color: .accentColor)
                                Text("Email").foregroundStyle(.primary)
                                Spacer(minLength: 0)
                                Text(accountEmail ?? "Change")
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    } else {
                        HStack(spacing: 14) {
                            SettingsIcon(systemName: "envelope.fill", color: .accentColor)
                            Text("Email")
                            Spacer(minLength: 0)
                            Text("None").foregroundStyle(.secondary)
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
                    Button { showingPasswordSheet = true } label: {
                        HStack(spacing: 14) {
                            SettingsIcon(systemName: "key.fill", color: .orange)
                            Text("Account Password").foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            if methods?.accountPasswordNeedsUpdate == true {
                                Text("Update").foregroundStyle(.orange)
                            } else {
                                Text(UserDefaults.standard.bool(forKey: MessagingService.hasAccountPasswordKey) ? "Change" : "Set")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tint(.primary)
                    NavigationLink(destination: PasskeysView(service: service)) {
                        SettingsNavRow(systemName: "person.badge.key.fill", color: .green, title: "Passkeys")
                    }
                    NavigationLink(destination: RecoveryKeyView(service: service, methods: methods)) {
                        SettingsNavRow(systemName: "key.horizontal.fill", color: .blue, title: "Recovery Key")
                    }
                    if hasEmail {
                        Button {
                            if (methods?.passkeys ?? 0) > 0 { showingRemoveEmail = true } else { showingAddPasskeyFirst = true }
                        } label: {
                            HStack(spacing: 14) {
                                SettingsIcon(systemName: "envelope.badge.shield.half.filled.fill", color: .gray)
                                Text("Remove Email").foregroundStyle(.primary)
                            }
                        }
                        .tint(.primary)
                    }
                } header: {
                    Text("Sign-In")
                } footer: {
                    Text(hasEmail
                         ? "Signing in on a new device needs your account password, a passkey or your recovery key."
                         : "No email is linked. Sign in with a passkey or your recovery key.")
                }

                if hasEmail {
                Section {
                    Toggle(isOn: Binding(
                        get: { emailDiscoverable },
                        set: { on in
                            let previous = emailDiscoverable
                            emailDiscoverable = on
                            Task {
                                do {
                                    try await service.setEmailDiscoverable(on)
                                } catch {
                                    emailDiscoverable = previous
                                    discoverabilityError = FriendlyError.message(for: error)
                                }
                            }
                        }
                    )) {
                        HStack(spacing: 14) {
                            SettingsIcon(systemName: "magnifyingglass", color: .blue)
                            Text("Find Me by Email")
                        }
                    }
                } footer: {
                    if let discoverabilityError { Text(discoverabilityError) }
                }
                }
            }

            Section {
                NavigationLink(destination: LinkedDevicesView(service: service)) {
                    SettingsNavRow(systemName: "laptopcomputer.and.iphone", color: .accentColor, title: "Linked Devices")
                }
            }

            Section {
                if !service.isDemoAccount {
                    Button(role: .destructive) {
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                        confirmingNuke = true
                    } label: {
                        HStack(spacing: 14) {
                            SettingsIcon(systemName: "flame.fill", color: .red, useColor: true)
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
                        SettingsIcon(systemName: "person.crop.circle.badge.xmark", color: .red, useColor: true)
                        Text(service.isDemoAccount ? "Reset Demo Account" : "Delete Account").foregroundStyle(.red)
                    }
                }
            }
        }
        .modifier(ThemedPageBackground())
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showingPasswordSheet) {
            AccountPasswordSheet(service: service, needsUpdate: methods?.accountPasswordNeedsUpdate == true)
        }
        .onChange(of: showingPasswordSheet) { _, showing in
            if !showing { Task { methods = try? await service.apiClient.signInMethods() } }
        }
        .navigationDestination(isPresented: $showingEmailSheet) {
            ChangeEmailSheet()
        }
        .onChange(of: showingEmailSheet) { _, showing in
            if !showing { accountEmail = model.accountEmail }
        }
        .onAppear { accountEmail = model.accountEmail }
        .task { methods = try? await service.apiClient.signInMethods() }
        .navigationDestination(isPresented: $showingRemoveEmail) {
            RemoveEmailSheet {
                accountEmail = nil
                emailDiscoverable = false
                Task { methods = try? await service.apiClient.signInMethods() }
            }
        }
        .alert("Add a Passkey First", isPresented: $showingAddPasskeyFirst) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Without an email, a passkey is how you sign in. Create one in Passkeys, save your recovery key, then remove your email.")
        }
        .sheet(isPresented: $showingQR) {
            MyQRCodeView(username: username, displayName: service.myDisplayName,
                         avatarData: service.myAvatarData, createInviteLink: {
                try await service.createContactInviteLink()
            })
        }
        .navigationDestination(isPresented: $showingDeleteAccount) {
            DeleteAccountSheet(service: service) {
                model.signOut(removeFromServer: false) // the account is already gone
            }
        }
        .confirmationDialog("Wipe ALL devices?", isPresented: $confirmingNuke, titleVisibility: .visible) {
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
            Text("Every device signed in to your account verifies a signed command, then deletes its messages and keys. This can't be undone.")
        }
        .alert("Emergency Wipe Sent", isPresented: $nukeSucceeded) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The wipe command was delivered. All devices will delete their messages and keys.")
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
    @AppStorage(InChatSounds.enabledKey) private var inChatSounds = true

    var body: some View {
        List {
            Section {
                Toggle(isOn: $inChatSounds) {
                    HStack(spacing: 14) {
                        SettingsIcon(systemName: "speaker.wave.2.fill", color: .accentColor)
                        Text("In-Chat Sounds")
                    }
                }
            } footer: {
                Text("A short sound when a message is sent or arrives in the chat you have open. Follows your ring/silent switch.")
            }

            Section {
                NavigationLink(destination: ChatFoldersView(service: service)) {
                    SettingsNavRow(systemName: "folder.fill", color: .accentColor, title: "Chat Folders")
                }
            } footer: {
                Text("Group chats into folders like Work or Family. Folders stay on this device.")
            }

            Section {
                NavigationLink(destination: ScheduledMessagesView(service: service)) {
                    SettingsNavRow(systemName: "clock.badge.checkmark", color: .accentColor, title: "Scheduled Messages")
                }
            } footer: {
                Text("Messages you've queued to send automatically at a later time.")
            }

            Section {
                NavigationLink(destination: BlockedContactsView(service: service)) {
                    SettingsNavRow(systemName: "person.crop.circle.badge.minus", color: .accentColor, title: "Blocked Contacts")
                }
            } footer: {
                Text("Blocked accounts can't message or call you.")
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
                NavigationLink(destination: StorageSettingsView(service: service)) {
                    SettingsNavRow(systemName: "internaldrive.fill", color: .accentColor, title: "Storage")
                }
                if service.isDemoAccount {
                    EmptyView()
                } else if service.keepsChatListWithAccount {
                    SettingsToggleRow(systemName: "clock.arrow.circlepath", title: "Back Up Message History",
                                      info: "Keeps an encrypted copy of your messages (text only, no photos or files) with your account, so they come back when you sign in on a new phone. Only your account password, passkeys or recovery key can unlock it; Relay can't read it. Disappearing and view-once messages, message requests and hidden chats are never included. Turning this off deletes the copy.",
                                      isOn: Binding(get: { historyBackup }, set: { enabled in
                                          historyBackup = enabled
                                          Task { await service.setHistoryBackupEnabled(enabled) }
                                      }))
                    if historyBackup {
                        HistoryBackupStatusRow(service: service)
                    }
                } else {
                    HStack(spacing: 14) {
                        SettingsIcon(systemName: "clock.arrow.circlepath", color: .accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Message History Backup")
                            Text("Add a passkey, recovery key or account password in Account to back up your messages.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !service.isDemoAccount {
                    NavigationLink(destination: ContactSyncView(service: service)) {
                        SettingsNavRow(systemName: "person.crop.circle.badge.checkmark", color: .accentColor, title: "Contact Syncing")
                    }
                }
            }

            if service.preKeyDesyncDropCount > 0 {
                Section {
                    HStack(spacing: 14) {
                        SettingsIcon(systemName: "key.horizontal.fill", color: .accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Some messages couldn't be shown").foregroundStyle(.primary)
                            Text(service.preKeyDesyncDropCount == 1
                                 ? "1 message couldn't be decrypted. Your encryption keys were refreshed automatically — ask the sender to resend it if it was important."
                                 : "\(service.preKeyDesyncDropCount) messages couldn't be decrypted. Your encryption keys were refreshed automatically — ask the sender to resend them if they were important.")
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
    @Environment(CallManager.self) private var callManager
    @State private var privateCallMode = CallManager.isPrivateCallModeEnabled
    @State private var showDirectCallsWarning = false
    @AppStorage(CallManager.callsInRecentsKey) private var callsInRecents = false
    @State private var notificationPrivacy: String = NotificationPreviewSetting.current.rawValue
    @AppStorage(PrivacyPreferences.incognitoKeyboardKey) private var incognitoKeyboard = true
    @AppStorage(PrivacyPreferences.sendTypingKey) private var sendTyping = true
    @AppStorage(PrivacyPreferences.linkPreviewsKey) private var linkPreviews = true
    @AppStorage(PrivacyPreferences.spotlightIndexingKey) private var spotlightIndexing = false
    @AppStorage(PrivacyPreferences.shareSuggestionsKey) private var shareSuggestions = false
    @AppStorage(ScamCheck.enabledKey) private var scamWarnings = true

    var body: some View {
        List {
            Section {
                NavigationLink(destination: ProxySettingsView()) {
                    HStack(spacing: 14) {
                        SettingsIcon(systemName: "network.badge.shield.half.filled", color: .accentColor)
                        Text("Proxy")
                        Spacer(minLength: 0)
                        Text(RelayProxy.isEnabled ? "On" : "Off").foregroundStyle(.secondary)
                    }
                }
            }
            Section("Activity") {
                SettingsToggleRow(systemName: "ellipsis.bubble.fill", title: "Send Typing Indicators",
                                  info: "When on, people you're chatting with can see when you're typing. When off, you'll still see theirs.",
                                  isOn: $sendTyping)
                SettingsToggleRow(systemName: "checkmark.circle.fill", title: "Read Receipts",
                                  info: "When on, people can see when you've read their messages.",
                                  isOn: Binding(get: { service.sendReadReceipts }, set: { service.sendReadReceipts = $0 }))
            }

            Section("Messaging") {
                SettingsToggleRow(systemName: "timer", title: "Send Delay",
                                  info: "Adds a small random delay before each message sends, making it harder to correlate your activity by timing.",
                                  isOn: Binding(get: { service.sendJitterEnabled }, set: { service.sendJitterEnabled = $0 }))
                SettingsToggleRow(systemName: "keyboard", title: "Incognito Keyboard",
                                  info: "Asks the system keyboard not to learn from or store what you type in Relay — in messages, search and group names.",
                                  isOn: Binding(get: { incognitoKeyboard }, set: { incognitoKeyboard = $0 }))
                #if DEBUG
                NavigationLink("Scam Self-Test (debug)") { ScamSelfTestView() }
                #endif
                SettingsToggleRow(systemName: "exclamationmark.shield", title: "Scam Warnings",
                                  info: "Relay checks incoming messages with links, money or code requests on your iPhone (with Apple Intelligence where available) and warns you if one looks like a scam. Nothing is sent anywhere, and nobody is reported unless you choose to.",
                                  isOn: $scamWarnings)
                SettingsToggleRow(systemName: "link", title: "Generate Link Previews",
                                  info: "When on, Relay fetches a preview for links you send, which connects your device to that website. Previews are never fetched for links you receive.",
                                  isOn: $linkPreviews)
            }

            Section {
                SettingsToggleRow(systemName: "magnifyingglass", title: "Show Chats in Search",
                                  info: "Adds your chat names to iPhone Search (Spotlight). The search index is stored by iOS outside Relay's encryption. Hidden chats are never added.",
                                  isOn: Binding(get: { spotlightIndexing }, set: { enabled in
                                      spotlightIndexing = enabled
                                      if enabled { service.refreshConversations() }  // re-index now
                                      else { SpotlightIndexer.deindexAll() }
                                  }))
                SettingsToggleRow(systemName: "square.and.arrow.up", title: "Suggest Chats in Share Sheet",
                                  info: "Lets iOS suggest chats you message in the Share Sheet and Siri. iOS keeps those suggestions, with chat names and photos, outside Relay's encryption. Hidden chats are never suggested.",
                                  isOn: Binding(get: { shareSuggestions }, set: { enabled in
                                      shareSuggestions = enabled
                                      if !enabled { INInteraction.deleteAll(completion: nil) }
                                  }))
            } header: {
                Text("System Integration")
            }

            Section("Notifications") {
                Picker(selection: $notificationPrivacy) {
                    Text("Name and Content").tag("full")
                    Text("Name Only").tag("nameOnly")
                    Text("No Name or Content").tag("none")
                } label: {
                    HStack(spacing: 14) {
                        SettingsIcon(systemName: "bell.badge.fill", color: .gray)
                        Text("Lock Screen Preview")
                    }
                }
                .pickerStyle(.navigationLink)
                .onChange(of: notificationPrivacy) { _, value in
                    UserDefaults(suiteName: AppModel.appGroupId)?.set(value, forKey: "relay.notificationPrivacy")
                }

                SettingsToggleRow(systemName: "bolt.fill", title: "Faster Alerts",
                                  info: "On: the encrypted message is delivered inside the push notification for instant alerts. Off (more private): the push is just a content-free wake and your device fetches the encrypted message from Relay, so Apple's push servers never carry it.",
                                  isOn: Binding(get: { service.pushIncludeContent }, set: { service.pushIncludeContent = $0 }))
            }

            Section {
                SettingsToggleRow(systemName: "phone.fill", title: "Relay-Only Calls",
                                  info: "Routes every call through Relay's relay server so the other person never sees your IP address. If the relay server can't be reached, the call fails instead of connecting directly.",
                                  isOn: Binding(get: { privateCallMode }, set: { newValue in
                                      if newValue {
                                          privateCallMode = true
                                          callManager.privateCallMode = true
                                      } else {
                                          showDirectCallsWarning = true
                                      }
                                  }))
                SettingsToggleRow(systemName: "clock.arrow.circlepath", title: "Show Calls in Recents",
                                  info: "Adds Relay calls to the Phone app's Recents list, which can sync to your other Apple devices through iCloud.",
                                  isOn: $callsInRecents)
            } header: {
                Text("Calls")
            } footer: {
                if !privateCallMode {
                    Text("Direct calls are on: the people you call can see your IP address, which can reveal your approximate location.")
                        .foregroundStyle(.red)
                }
            }
            .confirmationDialog("Allow direct calls?", isPresented: $showDirectCallsWarning, titleVisibility: .visible) {
                Button("Allow Direct Calls", role: .destructive) {
                    privateCallMode = false
                    callManager.privateCallMode = false
                }
                Button("Keep Relay-Only", role: .cancel) {}
            } message: {
                Text("Direct calls can connect faster, but they reveal your IP address — and with it your approximate location and network — to the person you're calling.")
            }

            Section("Media") {
                SettingsToggleRow(systemName: "wifi", title: "Wi-Fi Only Downloads",
                                  isOn: Binding(get: { UserDefaults.standard.bool(forKey: "relay.wifiOnlyDownload") },
                                                set: { UserDefaults.standard.set($0, forKey: "relay.wifiOnlyDownload") }))
            }

            Section {
                NavigationLink(destination: DataRetentionView()) {
                    HStack(spacing: 14) {
                        SettingsIcon(systemName: "doc.text.magnifyingglass", color: .gray)
                        Text("Data & Retention Policy")
                    }
                }
                Link(destination: LegalLinks.privacy) {
                    SettingsExternalRow(systemName: "hand.raised.fill", title: "Privacy Policy")
                }
                Link(destination: LegalLinks.terms) {
                    SettingsExternalRow(systemName: "doc.text.fill", title: "Terms of Service")
                }
                NavigationLink(destination: AcknowledgementsView()) {
                    SettingsNavRow(systemName: "heart.text.square.fill", color: .accentColor, title: "Acknowledgements")
                }
            } header: {
                Text("Policies & Legal")
            }
        }
        .modifier(ThemedPageBackground())
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Data & Retention Policy

private struct DataRetentionView: View {
    var body: some View {
        List {
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
                    detail: "IP addresses, connection timing, and envelope sizes are visible to the relay server and any network between you and it. TLS encrypts data in transit; Relay-Only Calls hides your IP from the people you call."
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
                Text("Removes downloaded copies of received photos, videos and files. They'll download again when you open them, as long as they're still available on the server.")
            }

            Section("Database") {
                LabeledContent("Encryption", value: "SQLCipher AES-256")
                LabeledContent("Location", value: "App Group Container")
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
            Text("Downloaded media will be removed from this device and re-downloaded when you view it. Media that's no longer on the server can't be recovered.")
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
    @AppStorage("relay.screenLockEnabled") private var screenLockEnabled = false
    @AppStorage("relay.screenLockTimeout") private var screenLockTimeout = 60

    var body: some View {
        List {
            Section("Encryption") {
                HStack(spacing: 14) {
                    SettingsIcon(systemName: "lock.shield.fill", color: .green)
                    LabeledContent("Protocol", value: "Signal (PQXDH)")
                }
                HStack(spacing: 14) {
                    SettingsIcon(systemName: "cylinder.split.1x2.fill", color: .blue)
                    LabeledContent("Storage", value: "SQLCipher AES-256")
                }
                HStack(spacing: 14) {
                    SettingsIcon(systemName: "key.fill", color: .orange)
                    LabeledContent("Keys", value: "Secure Enclave")
                }
            }

            Section("Screen Lock") {
                SettingsToggleRow(systemName: "faceid", title: "Screen Lock",
                                  info: "Require \(biometricTypeName) when returning to Relay after it's been in the background.",
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
                            SettingsIcon(systemName: "timer", color: .gray)
                            Text("Lock After")
                        }
                    }
                }
            }

            Section("Panic Mode") {
                SettingsToggleRow(systemName: "eye.slash.fill", title: "Panic Mode",
                                  info: "Hides selected chats behind a PIN. Long-press a conversation in the list to mark it hidden.",
                                  isOn: Binding(
                                    get: { panicMode.isEnabled },
                                    set: { enabled in
                                        if enabled { showingPanicSettings = true }
                                        else { panicMode.disable() }
                                    }))
                if panicMode.isEnabled {
                    Button("Configure Panic Mode") { showingPanicSettings = true }
                        .foregroundStyle(.tint)
                }
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

struct SettingsIcon: View {
    let systemName: String
    let color: Color
    /// Use `color` instead of neutral gray. Reserved for rows that signal danger
    /// (e.g. Emergency Wipe).
    var useColor: Bool = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background((useColor ? color : Color(.systemGray)).gradient, in: .rect(cornerRadius: 7))
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

/// Standard settings toggle row: gray icon, title, optional ⓘ, trailing
/// switch.
struct SettingsToggleRow: View {
    let systemName: String
    let title: String
    var info: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 14) {
            SettingsIcon(systemName: systemName, color: .gray)
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

    @Environment(\.dismiss) private var dismiss
    @State private var showingPINSetup = false

    var body: some View {
        Group {
            Form {
                Section {
                    Toggle("Enable Panic Mode", isOn: Binding(
                        get: { manager.isEnabled },
                        set: { enabled in
                            if enabled { showingPINSetup = true }
                            else { manager.disable() }
                        }
                    ))
                } footer: {
                    Text("When enabled, long-press a chat in the list to mark it hidden. Tap the lock icon to reveal with your PIN.")
                }

                if manager.isEnabled {
                    Section("Manage") {
                        Button("Change PIN") { showingPINSetup = true }
                        LabeledContent("Hidden Chats", value: "\(manager.hiddenIds.count)")
                    }
                }
            }
            .modifier(ThemedPageBackground())
            .navigationTitle("Panic Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingPINSetup) {
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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("PIN (at least 4 digits)", text: $pin)
                        .keyboardType(.numberPad)
                    SecureField("Confirm PIN", text: $confirm)
                        .keyboardType(.numberPad)
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
                Section {
                    Text("The PIN is stored as a one-way hash. If you forget it you will need to disable panic mode from Settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Set Panic PIN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.bold()
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard pin.count >= 4 else { error = "PIN must be at least 4 digits."; return }
        guard pin.allSatisfy({ $0.isASCII && $0.isNumber }) else { error = "PIN must contain digits only."; return }
        guard pin == confirm else { error = "PINs do not match."; return }
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
                } footer: {
                    Text("People can start a chat with you by opening this link or scanning your QR code — no phone number or email needed.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                        Button("Retry") { save() }
                    }
                }
            }
            .modifier(ThemedPageBackground())
            .navigationTitle("Change Username")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .bold()
                }
            }
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
    let title: String

    var body: some View {
        HStack(spacing: 14) {
            SettingsIcon(systemName: systemName, color: .accentColor)
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
                    if service.isDemoAccount {
                        Label {
                            Text("This is a demo account, so it's reset instead of deleted.")
                        } icon: {
                            Image(systemName: "arrow.counterclockwise.circle.fill").foregroundStyle(.orange)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("• Its devices are signed out and its keys and undelivered messages are removed from the server.")
                            Text("• All messages and media on this iPhone are erased.")
                            Text("• The same review sign-in works again afterwards.")
                            Text("• A normal account is deleted permanently, its username released.")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    } else {
                    Label {
                        Text("This permanently deletes your Relay account. It can't be undone.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("• Your username is released and people can no longer reach you.")
                        Text("• All your linked devices are signed out and removed.")
                        Text("• Undelivered messages, keys and your profile are deleted from the server.")
                        Text("• All messages and media on this iPhone are erased.")
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
                    Button(role: .destructive) {
                        delete()
                    } label: {
                        HStack {
                            Spacer()
                            if isDeleting {
                                ProgressView()
                            } else {
                                Text(service.isDemoAccount ? "Reset Demo Account" : "Delete Account Permanently").bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(!confirmed || isDeleting)
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

/// Supabase emails a code to the new address, then the relay re-keys its
/// email lookup (recovery and find-by-email).
private struct ChangeEmailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var newEmail = ""
    @State private var codeSent = false
    @State private var code = ""
    @State private var working = false
    @State private var errorMessage: String?

    private var normalizedEmail: String { newEmail.lowercased().trimmingCharacters(in: .whitespaces) }

    var body: some View {
        Group {
            Form {
                if !codeSent {
                    Section {
                        TextField("New email address", text: $newEmail)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } footer: {
                        footer("We'll send a code to the new address. Your email is used to recover your account and, if you turn it on, to let people find you.")
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
                    } header: {
                        Text("Code sent to \(normalizedEmail)")
                    } footer: {
                        footer("Enter the code from the email.")
                    }
                    Section {
                        Button("Send a new code") { sendCode() }.disabled(working)
                    }
                }
            }
            .modifier(ThemedPageBackground())
            .navigationTitle("Change Email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else if codeSent {
                        Button("Confirm") { confirm() }.bold().disabled((6...10).contains(code.count) == false)
                    } else {
                        Button("Send Code") { sendCode() }.bold().disabled(!normalizedEmail.contains("@"))
                    }
                }
            }
            .navigationBarBackButtonHidden(working)
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

private struct AccountPasswordSheet: View {
    let service: MessagingService
    var needsUpdate = false
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirm = ""
    @State private var saving = false
    @State private var errorMessage: String?

    private var valid: Bool { password.count >= 8 && password == confirm }

    var body: some View {
        Group {
            Form {
                Section {
                    SecureField("New password", text: $password)
                        .textContentType(.newPassword)
                    SecureField("Confirm password", text: $confirm)
                        .textContentType(.newPassword)
                } footer: {
                    Text(errorMessage ?? (needsUpdate
                        ? "Enter your account password again, or choose a new one. Relay now stores it differently, and until you do it can't be used to sign in on a new device."
                        : "At least 8 characters. You'll need it to recover your account by email and to sign in on a new device."))
                        .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
                }
            }
            .modifier(ThemedPageBackground())
            .navigationTitle("Account Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }.bold().disabled(!valid)
                    }
                }
            }
            .navigationBarBackButtonHidden(saving)
        }
    }

    private func save() {
        saving = true
        errorMessage = nil
        Task {
            do {
                try await service.setAccountPassword(password)
                dismiss()
            } catch {
                errorMessage = FriendlyError.message(for: error)
            }
            saving = false
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
