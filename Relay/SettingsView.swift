//
//  SettingsView.swift
//  Relay
//

import LocalAuthentication
import PhotosUI
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
    @State private var confirmingNuke = false
    @State private var nukeInProgress = false
    @State private var nukeError: String?
    @State private var nukeSucceeded = false
    @State private var showingDeleteAccount = false

    private var displayName: String {
        let name = service.myDisplayName ?? service.username
        return name?.isEmpty == false ? name! : "Unknown"
    }

    var body: some View {
        NavigationStack {
            List {

                // MARK: Profile hero
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
                    }
                    .buttonStyle(.plain)
                    .tint(.primary)
                }

                // MARK: Primary categories
                // A tidy single-column list of important categories, each
                // opening a sub-page. Niche tools (Scheduled Messages, Blocked)
                // now live inside "Chats"; storage/backup/sync inside "Data &
                // Storage" — keeping this top level focused.
                Section {
                    if service.username != nil {
                        NavigationLink(destination: AccountSettingsView(service: service)) {
                            SettingsNavRow(systemName: "person.crop.circle.fill", color: .accentColor, title: "Account")
                        }
                    }
                    NavigationLink(destination: AppearanceSettingsView()) {
                        SettingsNavRow(systemName: "paintbrush.fill", color: .accentColor, title: "Appearance")
                    }
                    NavigationLink(destination: ChatsSettingsView(service: service)) {
                        SettingsNavRow(systemName: "bubble.left.and.bubble.right.fill", color: .accentColor, title: "Chats")
                    }
                    NavigationLink(destination: PrivacySettingsView(service: service)) {
                        SettingsNavRow(systemName: "hand.raised.fill", color: .accentColor, title: "Privacy")
                    }
                    NavigationLink(destination: SecuritySettingsView(service: service)) {
                        SettingsNavRow(systemName: "lock.shield.fill", color: .accentColor, title: "Security")
                    }
                    NavigationLink(destination: LinkedDevicesView(service: service)) {
                        SettingsNavRow(systemName: "laptopcomputer.and.iphone", color: .accentColor, title: "Linked Devices")
                    }
                    NavigationLink(destination: DataStorageSettingsView(service: service)) {
                        SettingsNavRow(systemName: "internaldrive.fill", color: .accentColor, title: "Data & Storage")
                    }
                }

                // MARK: Invite
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

                // MARK: Support & legal
                Section {
                    Link(destination: LegalLinks.feedbackMail) {
                        SettingsExternalRow(systemName: "envelope.fill", title: "Send Feedback")
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
                    Text("About")
                }

                // MARK: Emergency Wipe
                Section {
                    Button(role: .destructive) {
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                        confirmingNuke = true
                    } label: {
                        HStack(spacing: 14) {
                            SettingsIcon(systemName: "flame.fill", color: .red, useColor: true)
                            Text("Emergency Wipe All Devices")
                                .foregroundStyle(.red)
                            Spacer(minLength: 0)
                            if nukeInProgress {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(nukeInProgress)
                } header: {
                    Text("Danger Zone")
                } footer: {
                    Text("Sends a signed wipe command to all devices on your account. Each device verifies the command before deleting its messages and keys.")
                }

                // MARK: Sign out / delete account
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
                    Button(role: .destructive) {
                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                        showingDeleteAccount = true
                    } label: {
                        HStack(spacing: 14) {
                            SettingsIcon(systemName: "person.crop.circle.badge.xmark", color: .red, useColor: true)
                            Text("Delete Account").foregroundStyle(.red)
                        }
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
            .navigationTitle("Profile")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ConnectionBadge(state: service.connectionState)
                }
            }
            .onAppear { avatarData = service.myAvatarData }
            .confirmationDialog(
                "Sign out and delete all local messages?",
                isPresented: $confirmingSignOut,
                titleVisibility: .visible
            ) {
                Button("Sign Out & Delete", role: .destructive) {
                    model.signOut()
                }
            } message: {
                Text("Message history only exists on this device — it cannot be recovered.")
            }
            .confirmationDialog(
                "Wipe ALL devices?",
                isPresented: $confirmingNuke,
                titleVisibility: .visible
            ) {
                Button("Wipe All Devices", role: .destructive) {
                    // Wiping every device must prove the owner is present:
                    // refuse (with an explanation) when no passcode is set.
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
                            nukeError = error.localizedDescription
                        }
                        nukeInProgress = false
                    }
                }
            } message: {
                Text("This will cryptographically wipe messages and keys on every device signed in to your account. This cannot be undone.")
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
            .sheet(isPresented: $showingEditProfile) {
                EditProfileSheet(service: service) { avatarData = service.myAvatarData }
            }
            .sheet(isPresented: $showingPanicSettings) {
                PanicModeSheet(manager: panicMode)
            }
            .sheet(isPresented: $showingDeleteAccount) {
                DeleteAccountSheet(service: service) {
                    model.signOut(removeFromServer: false) // the account is already gone
                }
            }
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
    @State private var showingQR = false
    @State private var linkCopied = false

    private var username: String { service.username ?? "" }
    private var addLink: String { "relaymsg.app/add/\(username)" }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    SettingsIcon(systemName: "at", color: .accentColor)
                    Text("Username")
                    Spacer(minLength: 0)
                    Text("@\(username)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Button {
                    SecurePasteboard.copy("https://\(addLink)")
                    linkCopied = true
                    Task { try? await Task.sleep(for: .seconds(2)); linkCopied = false }
                } label: {
                    HStack(spacing: 14) {
                        SettingsIcon(systemName: linkCopied ? "checkmark" : "link", color: .accentColor)
                        Text(linkCopied ? "Link Copied" : "Copy My Link").foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        Text(addLink)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .tint(.primary)
            } header: {
                Text("Identity")
            } footer: {
                Text("People can start a chat with you using your username, link, or QR code — no phone number or email needed.")
            }

            Section {
                Button { showingQR = true } label: {
                    HStack(spacing: 14) {
                        SettingsIcon(systemName: "qrcode", color: .accentColor)
                        Text("My QR Code").foregroundStyle(.primary)
                    }
                }
                .tint(.primary)
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingQR) {
            MyQRCodeView(username: username, createInviteLink: {
                try await service.createContactInviteLink()
            })
        }
    }
}

// MARK: - Chats sub-page

private struct ChatsSettingsView: View {
    let service: MessagingService

    var body: some View {
        List {
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
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Data & Storage sub-page

private struct DataStorageSettingsView: View {
    let service: MessagingService

    var body: some View {
        List {
            Section {
                NavigationLink(destination: StorageSettingsView(service: service)) {
                    SettingsNavRow(systemName: "internaldrive.fill", color: .accentColor, title: "Storage")
                }
                NavigationLink(destination: BackupView(service: service)) {
                    SettingsNavRow(systemName: "arrow.clockwise.icloud.fill", color: .accentColor, title: "Backup & Restore")
                }
                NavigationLink(destination: ContactSyncView(service: service)) {
                    SettingsNavRow(systemName: "person.crop.circle.badge.checkmark", color: .accentColor, title: "Contact Syncing")
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
        .navigationTitle("Data & Storage")
        .navigationBarTitleDisplayMode(.inline)
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

    var body: some View {
        List {
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
                SettingsToggleRow(systemName: "link", title: "Generate Link Previews",
                                  info: "When on, Relay fetches a preview for links you send, which connects your device to that website. Previews are never fetched for links you receive.",
                                  isOn: $linkPreviews)
            }

            Section {
                SettingsToggleRow(systemName: "magnifyingglass", title: "Show Chats in Search",
                                  info: "Adds your chat names to iPhone Search (Spotlight). The search index is stored by iOS outside Relay's encryption. Hidden chats are never added.",
                                  isOn: Binding(get: { spotlightIndexing }, set: { enabled in
                                      spotlightIndexing = enabled
                                      if enabled { service.refreshConversations() } // re-index now
                                      else { SpotlightIndexer.deindexAll() }
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
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Data & Retention Policy (Stage 8)

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

    /// Delegates to MessagingService so only re-downloadable blobs are removed
    /// and their attachment rows are reset to "not downloaded" (deleting the
    /// directory directly would destroy local-only Note to Self media and
    /// leave isDownloaded=true, so images could never re-download).
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
        .navigationTitle("Security")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPanicSettings) {
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
    @State private var statusDraft: String
    @State private var linkDrafts: [ProfileLink]
    @State private var avatarData: Data?
    @State private var avatarChanged = false
    @State private var profilePhoto: PhotosPickerItem?
    @State private var loadingPhoto = false
    @State private var showingChangeUsername = false

    init(service: MessagingService, onDone: @escaping () -> Void) {
        self.service = service
        self.onDone = onDone
        _displayNameDraft = State(initialValue: service.myDisplayName ?? "")
        _avatarData = State(initialValue: service.myAvatarData)
        _bioDraft = State(initialValue: UserDefaults.standard.string(forKey: "my.profile.bio") ?? "")
        _statusDraft = State(initialValue: UserDefaults.standard.string(forKey: "my.profile.status") ?? "")
        _linkDrafts = State(initialValue: service.myLinks)
    }

    private static let maxLinks = 5

    private var previewName: String {
        displayNameDraft.isEmpty ? (service.username ?? "?") : displayNameDraft
    }

    var body: some View {
        NavigationStack {
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

                Section("Name") {
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
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .tint(.primary)
                }

                Section {
                    TextField("About (optional)", text: $statusDraft)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                } header: {
                    Text("Status")
                } footer: {
                    Text("A short message shown under your name.")
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
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if loadingPhoto {
                        ProgressView()
                    } else {
                        Button("Save") { saveAndDismiss() }.bold()
                    }
                }
            }
            .onChange(of: profilePhoto) { _, item in loadPhoto(item) }
            .sheet(isPresented: $showingChangeUsername) {
                ChangeUsernameSheet(currentUsername: service.username ?? "")
            }
        }
    }

    private func saveAndDismiss() {
        service.setMyDisplayName(displayNameDraft)
        // Only commit the avatar (which distributes to peers) if it actually
        // changed in this editing session — nothing leaves the sheet until Save.
        if avatarChanged {
            service.setMyAvatarData(avatarData)
        }
        // Distributes to peers over the E2EE profile channel (bumps revision only
        // if changed). Nothing left the sheet until this Save.
        service.setMyProfileText(status: statusDraft, bio: bioDraft, links: linkDrafts)
        onDone()
        dismiss()
    }

    // Holds the new avatar locally only; it isn't distributed until Save.
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
                  let image = UIImage(data: data),
                  let downscaled = image.avatarJPEG() else { return }
            setAvatar(downscaled)
        }
    }
}

// MARK: - Settings icon (colored square, iOS Settings style)

struct SettingsIcon: View {
    let systemName: String
    let color: Color
    /// Opt-in: use the provided `color` instead of the default neutral gray.
    /// Reserved for rows that need to signal danger (e.g. Emergency Wipe).
    var useColor: Bool = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            // Unified to a neutral gray for a consistent, non-rainbow settings
            // look; `useColor` opts a row back into its explicit `color`.
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

/// A small white ⓘ button that surfaces a one-shot explanation in a native
/// alert. Self-contained (owns its own presentation) so any settings row can
/// drop one in without plumbing shared state. Use only where a title isn't
/// self-explanatory.
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

/// The standard settings toggle row: gray icon, self-explanatory title, an
/// optional ⓘ for detail, and a trailing switch. One implementation shared by
/// every settings page so rows look and behave identically.
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
            if let imageData, let ui = UIImage(data: imageData) {
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

    private var avatarColor: Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green]
        var hash = 0
        for scalar in name.unicodeScalars { hash = (hash &* 31 &+ Int(scalar.value)) }
        return palette[abs(hash) % palette.count]
    }
}

// MARK: - PanicModeSheet (accessed via Security settings or 5-tap on version)

struct PanicModeSheet: View {
    let manager: PanicModeManager

    @Environment(\.dismiss) private var dismiss
    @State private var showingPINSetup = false

    var body: some View {
        NavigationStack {
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
        .presentationDetents([.medium])
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
        NavigationStack {
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
            .navigationTitle("Change Username")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
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

private struct InviteShareSheet: UIViewControllerRepresentable {
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
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Delete account

/// Permanent account deletion (App Store Guideline 5.1.1(v)). Requires typing
/// DELETE, deletes the account on the relay, then wipes this device.
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
        NavigationStack {
            Form {
                Section {
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
                                Text("Delete Account Permanently").bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(!confirmed || isDeleting)
                }
            }
            .navigationTitle("Delete Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isDeleting)
                }
            }
            .interactiveDismissDisabled(isDeleting)
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
                try await service.deleteAccount()
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
