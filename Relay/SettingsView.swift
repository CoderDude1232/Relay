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
    @State private var showingQR = false
    @State private var showingEditProfile = false
    @State private var showingChangeUsername = false
    @State private var avatarData: Data?
    @State private var panicMode = PanicModeManager.shared
    @State private var showingPanicSettings = false
    @State private var versionTapCount = 0
    @State private var showingInvite = false
    @State private var confirmingNuke = false
    @State private var nukeInProgress = false
    @State private var nukeError: String?
    @State private var nukeSucceeded = false
    @State private var usernameCopied = false

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
                                Image(systemName: "pencil")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 22, height: 22)
                                    .background(Color.accentColor, in: .circle)
                                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                                    .offset(x: 2, y: 2)
                                    .accessibilityHidden(true)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(displayName)
                                    .font(.title3.bold())
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if let username = service.username {
                                    Text(username)
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

                // MARK: Account
                Section("Account") {
                    Button { showingChangeUsername = true } label: {
                        HStack(spacing: 14) {
                            SettingsIcon(systemName: "at", color: .blue)
                            Text("Username").foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            if let username = service.username {
                                Text(usernameCopied ? "Copied!" : "@\(username)")
                                    .foregroundStyle(usernameCopied ? .green : .secondary)
                                    .font(.subheadline)
                                    .animation(.easeInOut(duration: 0.2), value: usernameCopied)
                            }
                        }
                    }
                    .tint(.primary)
                    .contextMenu {
                        if let username = service.username {
                            Button {
                                UIPasteboard.general.string = "@\(username)"
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                usernameCopied = true
                                Task {
                                    try? await Task.sleep(for: .seconds(2))
                                    usernameCopied = false
                                }
                            } label: {
                                Label("Copy Username", systemImage: "doc.on.doc")
                            }
                            Button { showingChangeUsername = true } label: {
                                Label("Change Username", systemImage: "pencil")
                            }
                        }
                    }
                    .sheet(isPresented: $showingChangeUsername) {
                        ChangeUsernameSheet(currentUsername: service.username ?? "")
                    }

                    if let username = service.username {
                        Button { showingQR = true } label: {
                            HStack(spacing: 14) {
                                SettingsIcon(systemName: "qrcode", color: .indigo)
                                Text("My QR Code").foregroundStyle(.primary)
                            }
                        }
                        .tint(.primary)
                        .sheet(isPresented: $showingQR) {
                            MyQRCodeView(username: username, createInviteLink: {
                                try await service.createContactInviteLink()
                            })
                        }
                    }
                }

                // MARK: Chats settings
                Section("Chats") {
                    NavigationLink(destination: AppearanceSettingsView()) {
                        SettingsNavRow(systemName: "paintbrush.fill", color: .purple, title: "Appearance")
                    }
                    NavigationLink(destination: ScheduledMessagesView(service: service)) {
                        SettingsNavRow(systemName: "clock.badge.checkmark", color: .mint, title: "Scheduled Messages")
                    }
                    NavigationLink(destination: BlockedContactsView(service: service)) {
                        SettingsNavRow(systemName: "person.crop.circle.badge.minus", color: .red, title: "Blocked Contacts")
                    }
                }

                // MARK: Privacy & Security settings
                Section("Privacy & Security") {
                    NavigationLink(destination: PrivacySettingsView(service: service)) {
                        SettingsNavRow(systemName: "hand.raised.fill", color: .blue, title: "Privacy")
                    }
                    NavigationLink(destination: SecuritySettingsView(service: service)) {
                        SettingsNavRow(systemName: "lock.shield.fill", color: .green, title: "Security")
                    }
                    NavigationLink(destination: LinkedDevicesView(service: service)) {
                        SettingsNavRow(systemName: "iphone", color: .teal, title: "Linked Devices")
                    }
                }

                // MARK: Data & Devices settings
                Section("Data & Devices") {
                    NavigationLink(destination: StorageSettingsView(service: service)) {
                        SettingsNavRow(systemName: "internaldrive.fill", color: .orange, title: "Storage")
                    }
                    NavigationLink(destination: BackupView(service: service)) {
                        SettingsNavRow(systemName: "arrow.clockwise.icloud.fill", color: .indigo, title: "Backup & Export")
                    }
                    NavigationLink(destination: ContactSyncView(service: service)) {
                        SettingsNavRow(systemName: "person.crop.circle.badge.checkmark", color: .cyan, title: "Contact Syncing")
                    }
                }

                // MARK: Invite
                Section {
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

                // MARK: Emergency Wipe
                Section {
                    Button(role: .destructive) {
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                        confirmingNuke = true
                    } label: {
                        HStack(spacing: 14) {
                            SettingsIcon(systemName: "flame.fill", color: .red)
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

                // MARK: Sign out
                Section {
                    Button("Sign Out", role: .destructive) {
                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                        confirmingSignOut = true
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
                    nukeInProgress = true
                    Task {
                        let ok = await BiometricGate.authenticate(reason: "Confirm emergency wipe of all devices")
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
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

}

// MARK: - Privacy sub-page

struct PrivacySettingsView: View {
    let service: MessagingService
    @Environment(CallManager.self) private var callManager
    @State private var privateCallMode = UserDefaults.standard.bool(forKey: "relay.privateCallMode")
    @State private var notificationPrivacy: String = UserDefaults(suiteName: AppModel.appGroupId)?.string(forKey: "relay.notificationPrivacy") ?? "full"

    var body: some View {
        List {
            Section("Messaging") {
                toggleRow("checkmark.circle.fill", .blue, "Read Receipts",
                          get: { service.sendReadReceipts }, set: { service.sendReadReceipts = $0 })
                toggleRow("eye.slash.fill", .gray, "Hide Last Seen",
                          get: { service.hideLastSeen }, set: { service.hideLastSeen = $0 })
                toggleRow("timer", .indigo, "Send Delay",
                          get: { service.sendJitterEnabled }, set: { service.sendJitterEnabled = $0 })
                toggleRow("shield.lefthalf.filled", .purple, "Sealed Sender",
                          get: { service.sealedSenderEnabled }, set: { service.sealedSenderEnabled = $0 })
            }

            Section("Notifications") {
                Picker(selection: $notificationPrivacy) {
                    Text("Name and Content").tag("full")
                    Text("Name Only").tag("nameOnly")
                    Text("No Name or Content").tag("none")
                } label: {
                    HStack(spacing: 14) {
                        SettingsIcon(systemName: "bell.badge.fill", color: .blue)
                        Text("Lock Screen Preview")
                    }
                }
                .pickerStyle(.navigationLink)
                .onChange(of: notificationPrivacy) { _, value in
                    UserDefaults(suiteName: AppModel.appGroupId)?.set(value, forKey: "relay.notificationPrivacy")
                }
            }

            Section("Calls") {
                toggleRow("phone.fill", .green, "Private Call Mode",
                          get: { privateCallMode },
                          set: { privateCallMode = $0; callManager.privateCallMode = $0 })
            }

            Section("Media") {
                toggleRow("wifi", .blue, "Wi-Fi Only Downloads",
                          get: { UserDefaults.standard.bool(forKey: "relay.wifiOnlyDownload") },
                          set: { UserDefaults.standard.set($0, forKey: "relay.wifiOnlyDownload") })
            }

            Section {
                NavigationLink(destination: DataRetentionView()) {
                    HStack(spacing: 14) {
                        SettingsIcon(systemName: "doc.text.magnifyingglass", color: .indigo)
                        Text("Data & Retention Policy")
                    }
                }
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A compact single-line settings toggle: icon + title, no description.
    private func toggleRow(
        _ systemName: String, _ color: Color, _ title: String,
        get: @escaping () -> Bool, set: @escaping (Bool) -> Void
    ) -> some View {
        Toggle(isOn: Binding(get: get, set: set)) {
            HStack(spacing: 14) {
                SettingsIcon(systemName: systemName, color: color)
                Text(title)
            }
        }
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
                    icon: "key.slash", color: .orange,
                    title: "Private Keys",
                    detail: "Identity and session keys are generated on-device and stored in the Secure Enclave or Keychain. They never leave your device."
                )
                RetentionRow(
                    icon: "eye.slash.fill", color: .gray,
                    title: "Server Logs",
                    detail: "The relay server redacts bearer tokens, account IDs, and message metadata before writing any log line. No request bodies are logged."
                )
            } header: {
                Text("What the Server Never Stores")
            }

            Section {
                RetentionRow(
                    icon: "envelope.fill", color: .blue,
                    title: "Offline Message Queue",
                    detail: "Encrypted envelopes queued for offline delivery are kept for up to 30 days, up to 500 envelopes per device, and up to 512 KiB each. Delivered and acknowledged envelopes are deleted immediately."
                )
                RetentionRow(
                    icon: "key.horizontal.fill", color: .yellow,
                    title: "Prekeys",
                    detail: "One-time prekeys are consumed on session establishment and deleted from the server. Signed prekeys and Kyber prekeys are replaced when you rotate them."
                )
                RetentionRow(
                    icon: "person.fill", color: .teal,
                    title: "Account Registration",
                    detail: "Username, bcrypt-hashed password, and device list are stored for the lifetime of the account. Account deletion removes all associated records."
                )
                RetentionRow(
                    icon: "paperclip", color: .purple,
                    title: "Attachments",
                    detail: "Encrypted attachment blobs are stored for 30 days. After that they are automatically deleted. The server cannot decrypt attachment content."
                )
            } header: {
                Text("What the Server Stores")
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
                    detail: "IP addresses, connection timing, and envelope sizes are visible to the relay server and any network between you and it. TLS encrypts data in transit; Private Call Mode hides your IP from call peers."
                )
            } header: {
                Text("Metadata Limits")
            } footer: {
                Text("Relay is open-source. The server code in this repository implements these policies exactly.")
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

    var body: some View {
        List {
            Section {
                LabeledContent("Cached Media", value: formattedSize(cacheSize))
                Button(role: .destructive) {
                    clearCache()
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
                Text("Downloaded attachments cached on this device. They re-download on demand.")
            }

            Section("Database") {
                LabeledContent("Encryption", value: "SQLCipher AES-256")
                LabeledContent("Location", value: "App Group Container")
            }
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { cacheSize = attachmentCacheSize() }
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

    private func clearCache() {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppModel.appGroupId
        ) else { return }
        isClearing = true
        Task {
            let dir = container.appendingPathComponent("attachments")
            if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for file in files { try? FileManager.default.removeItem(at: file) }
            }
            await MainActor.run { cacheSize = 0; isClearing = false }
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

            Section {
                Toggle(isOn: $screenLockEnabled) {
                    HStack(spacing: 14) {
                        SettingsIcon(systemName: "faceid", color: .indigo)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Screen Lock")
                            Text("Require Face ID or Touch ID when opening Relay")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if screenLockEnabled {
                    Picker(selection: $screenLockTimeout) {
                        Text("Immediately").tag(0)
                        Text("After 1 minute").tag(60)
                        Text("After 5 minutes").tag(300)
                        Text("After 15 minutes").tag(900)
                        Text("After 1 hour").tag(3600)
                    } label: {
                        HStack(spacing: 14) {
                            SettingsIcon(systemName: "timer", color: .orange)
                            Text("Lock After")
                        }
                    }
                }
            } header: {
                Text("Screen Lock")
            } footer: {
                Text(screenLockEnabled
                    ? "Relay will ask for \(biometricTypeName) when you return to the app after it has been in the background."
                    : "Protect your chats with Face ID or Touch ID when reopening the app.")
            }

            Section {
                Toggle("Panic Mode", isOn: Binding(
                    get: { panicMode.isEnabled },
                    set: { enabled in
                        if enabled { showingPanicSettings = true }
                        else { panicMode.disable() }
                    }
                ))
                if panicMode.isEnabled {
                    Button("Configure Panic Mode") { showingPanicSettings = true }
                        .foregroundStyle(.tint)
                }
            } header: {
                Text("Panic Mode")
            } footer: {
                Text("Hides selected chats behind a PIN. Long-press a conversation in the list to mark it hidden.")
            }
        }
        .navigationTitle("Security")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPanicSettings) {
            PanicModeSheet(manager: panicMode)
        }
    }

    private var biometricTypeName: String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return "passcode"
        }
        return context.biometryType == .faceID ? "Face ID" : "Touch ID"
    }
}

// MARK: - Edit Profile Sheet

private struct EditProfileSheet: View {
    let service: MessagingService
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var displayNameDraft: String
    @State private var bioDraft: String
    @State private var statusDraft: String
    @State private var avatarData: Data?
    @State private var profilePhoto: PhotosPickerItem?
    @State private var loadingPhoto = false

    init(service: MessagingService, onDone: @escaping () -> Void) {
        self.service = service
        self.onDone = onDone
        _displayNameDraft = State(initialValue: service.myDisplayName ?? "")
        _avatarData = State(initialValue: service.myAvatarData)
        _bioDraft = State(initialValue: UserDefaults.standard.string(forKey: "my.profile.bio") ?? "")
        _statusDraft = State(initialValue: UserDefaults.standard.string(forKey: "my.profile.status") ?? "")
    }

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
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(6)
                                    .background(Color.accentColor, in: .circle)
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
                    if let username = service.username {
                        LabeledContent("Email", value: username)
                            .foregroundStyle(.secondary)
                    }
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
                    Text("Shown on your profile card. Not end-to-end encrypted.")
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
        }
    }

    private func saveAndDismiss() {
        service.setMyDisplayName(displayNameDraft)
        UserDefaults.standard.set(bioDraft, forKey: "my.profile.bio")
        UserDefaults.standard.set(statusDraft, forKey: "my.profile.status")
        onDone()
        dismiss()
    }

    private func setAvatar(_ data: Data?) {
        avatarData = data
        service.setMyAvatarData(data)
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

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(color.gradient, in: .rect(cornerRadius: 7))
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
                    SecureField("PIN (min 4 characters)", text: $pin)
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
        guard pin == confirm else { error = "PINs do not match."; return }
        manager.enable(pin: pin)
        dismiss()
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
        case idle, checking, available, taken, invalid(String), unchanged
    }

    private var canSave: Bool {
        guard !isLoading else { return false }
        if case .available = usernameStatus { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("@")
                            .foregroundStyle(.secondary)
                        TextField("username", text: $username)
                            .focused($isFocused)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit { isFocused = false }
                            .onChange(of: username) { _, new in scheduleCheck(new) }
                        statusIcon
                    }
                } footer: {
                    statusMessage
                        .padding(.top, 2)
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
        case .taken, .invalid: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        switch usernameStatus {
        case .idle:
            Text("3–20 characters, letters, digits and underscores.")
        case .unchanged:
            Text("This is already your username.")
        case .checking:
            Text("Checking availability…")
        case .available:
            Text("@\(username) is available").foregroundStyle(.green)
        case .taken:
            Text("@\(username) is already taken").foregroundStyle(.red)
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
        if let reason = validationError(lower) { usernameStatus = .invalid(reason); return }
        usernameStatus = .checking
        checkTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let available = await model.checkUsernameAvailable(lower)
            guard !Task.isCancelled else { return }
            usernameStatus = available ? .available : .taken
        }
    }

    private func validationError(_ u: String) -> String? {
        if u.count < 3  { return "Too short — minimum 3 characters." }
        if u.count > 20 { return "Too long — maximum 20 characters." }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        if u.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "Only letters, digits and underscores."
        }
        return nil
    }

    private func save() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                try await model.changeUsername(username)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

// MARK: - Invite share sheet

private struct InviteShareSheet: UIViewControllerRepresentable {
    let username: String?

    private var items: [Any] {
        var message = "Hey! I'm using Relay, an end-to-end encrypted messenger with no metadata collection. No ads, no tracking, no logs."
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
