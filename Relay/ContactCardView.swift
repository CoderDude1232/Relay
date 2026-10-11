//
//  ContactCardView.swift
//  Relay
//
//  Contact info sheet for a 1:1 peer.
//

import RelayKit
import SecureStorage
import SwiftUI

struct ContactCardView: View {
    let service: MessagingService
    let conversationId: String
    var onActivateSearch: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(CallManager.self) private var callManager

    @State private var nickname = ""
    @State private var editingNickname = false
    @State private var nicknameDraft = ""
    @State private var accountIdCopied = false
    @State private var confirmResetSession = false
    @State private var confirmBlock = false
    @State private var showingReport = false
    @State private var photoExpanded = false
    @Namespace private var photoNamespace

    private var conversation: Conversation? {
        service.conversations.first { $0.id == conversationId }
    }
    private var account: String { conversation?.peerAccount ?? "" }
    private var isNoteToSelf: Bool { account == service.noteToSelfAccount }
    /// Block/Report don't apply to Note to Self or the local Relay notices account.
    private var canBlockOrReport: Bool {
        !account.isEmpty && !isNoteToSelf && account != service.relayOfficialAccount
    }
    private var displayName: String { service.displayName(forAccount: account) }
    private var username: String? { service.username(forAccount: account) }
    private var peerBio: String { service.peerBio(forAccount: account) }
    private var mutualGroups: [(id: String, name: String)] {
        isNoteToSelf ? [] : service.mutualGroups(with: account)
    }
    private var peerLinks: [ProfileLink] { service.peerLinks(forAccount: account) }

    private var disappearingLabel: String {
        guard let s = conversation?.disappearingSeconds, s > 0 else { return "Off" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    var body: some View {
        cardBody
            .overlay {
                if photoExpanded {
                    ExpandedPhoto(
                        name: displayName,
                        imageData: service.peerAvatarData(forAccount: account),
                        namespace: photoNamespace
                    ) {
                        withAnimation(.spring(duration: 0.35, bounce: 0.1)) { photoExpanded = false }
                    }
                }
            }
    }

    private var cardBody: some View {
        NavigationStack {
            List {

                // MARK: Header
                Section {
                    VStack(spacing: 10) {
                        Button {
                            withAnimation(.spring(duration: 0.4, bounce: 0.2)) { photoExpanded = true }
                        } label: {
                            AvatarView(
                                name: displayName, size: 82,
                                imageData: service.peerAvatarData(forAccount: account)
                            )
                            .matchedGeometryEffect(id: "photo", in: photoNamespace, isSource: !photoExpanded)
                            .opacity(photoExpanded ? 0 : 1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(displayName)'s photo")
                        .accessibilityHint("Shows it larger")
                        Text(displayName).font(.title2.bold())
                        if let username {
                            Text("@\(username)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if !peerBio.isEmpty {
                            Text(peerBio)
                                .font(.callout)
                                .multilineTextAlignment(.center)
                                .textSelection(.enabled)
                                .padding(.top, 4)
                                .padding(.horizontal, 12)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                // MARK: Quick actions
                Section {
                    HStack(spacing: 10) {
                        if !isNoteToSelf {
                            quickAction(icon: "video.fill", label: "Video") {
                                dismiss()
                                Task {
                                    await callManager.startCall(
                                        peerAccount: account, peerName: displayName, kind: .video)
                                }
                            }
                            quickAction(icon: "phone.fill", label: "Voice") {
                                dismiss()
                                Task {
                                    await callManager.startCall(
                                        peerAccount: account, peerName: displayName)
                                }
                            }
                        }
                        quickAction(icon: service.isConversationMuted(conversationId) ? "bell.fill" : "bell.slash.fill",
                                    label: service.isConversationMuted(conversationId) ? "Unmute" : "Mute") {
                            service.setConversationMuted(conversationId, muted: !service.isConversationMuted(conversationId))
                        }
                        quickAction(icon: "magnifyingglass", label: "Search") {
                            dismiss()
                            onActivateSearch?()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 2)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                // MARK: Conversation settings
                Section {
                    NavigationLink {
                        DisappearingSheet(service: service, conversationId: conversationId)
                    } label: {
                        HStack(spacing: 14) {
                            SettingsIcon(systemName: "timer", color: .orange)
                            Text("Disappearing Messages").foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            Text(disappearingLabel).foregroundStyle(.secondary)
                        }
                    }

                    contactRow(icon: "pencil", color: .gray,
                               title: "Nickname",
                               value: nickname.isEmpty ? "None" : nickname) {
                        nicknameDraft = nickname
                        editingNickname = true
                    }

                    NavigationLink(destination: AppearanceSettingsView()) {
                        SettingsNavRow(systemName: "paintbrush.fill", color: .purple, title: "Chat Appearance")
                    }
                    NavigationLink(destination: MediaGalleryView(service: service, conversationId: conversationId)) {
                        SettingsNavRow(systemName: "photo.stack.fill", color: .teal, title: "Media")
                    }
                    NavigationLink(destination: StarredMessagesView(service: service, conversationId: conversationId, peerName: displayName)) {
                        SettingsNavRow(systemName: "star.fill", color: .yellow, title: "Starred Messages")
                    }
                    NavigationLink(destination: VerificationView(service: service, conversationId: conversationId, peerName: displayName)) {
                        SettingsNavRow(systemName: "checkmark.shield.fill", color: .green, title: "Safety Number")
                    }
                    if let conv = service.conversations.first(where: { $0.id == conversationId }) {
                        NavigationLink(destination: ChatPrivacySettingsView(service: service, conversation: conv)) {
                            SettingsNavRow(systemName: "slider.horizontal.3", color: .blue, title: "Chat Settings")
                        }
                    }
                }

                // MARK: Links
                if !peerLinks.isEmpty {
                    Section("Links") {
                        ForEach(peerLinks) { link in
                            // Peer-supplied: only open http(s), never tel:,
                            // sms:, relay:// or other schemes hidden behind a label.
                            if let url = Self.safeWebURL(link.url) {
                                Link(destination: url) {
                                    linkRow(label: link.label, url: link.url, tappable: true)
                                }
                            } else {
                                linkRow(label: link.label, url: link.url, tappable: false)
                            }
                        }
                    }
                }

                // MARK: Mutual groups
                if !mutualGroups.isEmpty {
                    Section(mutualGroups.count == 1 ? "1 Group in Common" : "\(mutualGroups.count) Groups in Common") {
                        ForEach(mutualGroups, id: \.id) { group in
                            HStack(spacing: 14) {
                                AvatarView(name: group.name, size: 30,
                                           imageData: service.group(for: group.id)?.avatarData)
                                Text(group.name).foregroundStyle(.primary)
                            }
                        }
                    }
                }

                // MARK: Account
                Section("Account") {
                    Button {
                        SecurePasteboard.copy(account)
                        accountIdCopied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            accountIdCopied = false
                        }
                    } label: {
                        HStack {
                            Text("Account ID")
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            Text(accountIdCopied ? "Copied!" : account)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(accountIdCopied ? .green : .secondary)
                            Image(systemName: accountIdCopied ? "checkmark" : "doc.on.doc")
                                .font(.caption)
                                .foregroundStyle(accountIdCopied ? .green : .secondary)
                        }
                    }
                    .tint(.primary)
                }

                // MARK: Block and report
                if canBlockOrReport {
                    Section {
                        let blocked = service.isBlocked(account)
                        Button {
                            if blocked { service.unblockAccount(account) }
                            else { confirmBlock = true }
                        } label: {
                            Label(
                                blocked ? "Unblock \(displayName)" : "Block \(displayName)",
                                systemImage: blocked ? "checkmark.circle" : "nosign"
                            )
                        }
                        .tint(blocked ? .primary : .red)

                        Button {
                            showingReport = true
                        } label: {
                            Label("Report \(displayName)", systemImage: "exclamationmark.bubble")
                        }
                        .tint(.red)
                    } footer: {
                        Text("Reports go to the Relay team. Messages are only included if you choose to share them.")
                    }
                }

                // MARK: Advanced
                if !isNoteToSelf {
                    Section {
                        DisclosureGroup("Troubleshooting") {
                            Button {
                                confirmResetSession = true
                            } label: {
                                Label("Fix Delivery Problems", systemImage: "arrow.triangle.2.circlepath")
                            }
                            Text("Starts a fresh encrypted connection with this person. Use it only if your messages keep showing \"Not Delivered\" while you're online.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Advanced")
                    }
                }
            }
            .navigationTitle(displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { saveAndDismiss() }
                }
            }
            .onAppear { nickname = service.nickname(forAccount: account) ?? "" }
            .confirmationDialog("Fix delivery problems with \(displayName)?", isPresented: $confirmResetSession, titleVisibility: .visible) {
                Button("Start Fresh Connection", role: .destructive) { service.resetSession(withPeer: account) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your next message will start a fresh encrypted connection with this person. Your chat history stays as it is.")
            }
            .confirmationDialog("Block \(displayName)?", isPresented: $confirmBlock, titleVisibility: .visible) {
                Button("Block", role: .destructive) { service.blockAccount(account) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Blocked contacts can't message or call you. You can unblock them later in Profile → Chats → Blocked Contacts.")
            }
            .sheet(isPresented: $showingReport) {
                ReportContactSheet(service: service, account: account, displayName: displayName)
            }
            .alert("Nickname", isPresented: $editingNickname) {
                TextField("Custom name (optional)", text: $nicknameDraft)
                    .autocorrectionDisabled()
                Button("Save") {
                    nickname = nicknameDraft
                    service.setNickname(nicknameDraft, forAccount: account)
                }
                if !nickname.isEmpty {
                    Button("Clear", role: .destructive) {
                        nickname = ""
                        service.setNickname("", forAccount: account)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Shown only to you.")
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func quickAction(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 72, height: 46)
                    .glassCompat(in: .rect(cornerRadius: 18))
                Text(label)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func linkRow(label: String, url: String, tappable: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if !label.isEmpty {
                    Text(label).foregroundStyle(.primary)
                }
                if !url.isEmpty {
                    Text(url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            if tappable {
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func contactRow(
        icon: String, color: Color, title: String, value: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                SettingsIcon(systemName: icon, color: color)
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 0)
                Text(value).foregroundStyle(.secondary)
            }
        }
        .tint(.primary)
    }

    private func saveAndDismiss() {
        service.setNickname(nickname, forAccount: account)
        dismiss()
    }

    /// Returns the URL only if it's an absolute http/https link with a host.
    static func safeWebURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty else { return nil }
        return url
    }
}

/// A contact's photo blown up to fill the width; tap or swipe down to close.
private struct ExpandedPhoto: View {
    let name: String
    let imageData: Data?
    let namespace: Namespace.ID
    let onClose: () -> Void

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) - 32
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .transition(.opacity)
                VStack(spacing: 16) {
                    Group {
                        if let data = imageData, let image = DecodedImageCache.image(for: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: side, height: side)
                                .clipShape(.rect(cornerRadius: 28, style: .continuous))
                        } else {
                            AvatarView(name: name, size: side * 0.8)
                        }
                    }
                    .matchedGeometryEffect(id: "photo", in: namespace)
                    .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
                    Text(name)
                        .font(.title2.bold())
                        .transition(.opacity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .contentShape(.rect)
            .onTapGesture(perform: onClose)
            .gesture(DragGesture(minimumDistance: 20).onEnded { if $0.translation.height > 60 { onClose() } })
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("\(name)'s photo")
            .accessibilityHint("Closes")
        }
    }
}

// MARK: - Report sheet

/// Report a contact to the Relay team, with optional details and, only on
/// explicit opt-in, the last 10 received messages.
struct ReportContactSheet: View {
    let service: MessagingService
    let account: String
    let displayName: String

    @Environment(\.dismiss) private var dismiss
    @State private var reason: ReportReason = .spam
    @State private var details = ""
    @State private var includeMessages = false
    @State private var alsoBlock = true
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var sent = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Reason", selection: $reason) {
                        ForEach(ReportReason.allCases) { r in
                            Text(r.title).tag(r)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Why are you reporting \(displayName)?")
                }

                Section {
                    TextField("Add details (optional)", text: $details, axis: .vertical)
                        .lineLimit(3...6)
                } footer: {
                    Text("\(details.count)/2000")
                        .foregroundStyle(details.count > 2000 ? .red : .secondary)
                }

                Section {
                    Toggle("Include last \(MessagingService.reportMessageLimit) messages", isOn: $includeMessages)
                } footer: {
                    Text("Relay is end-to-end encrypted, so we can't see your chats. If you turn this on, the text of the last \(MessagingService.reportMessageLimit) messages \(displayName) sent you is shared with the Relay team for review. Nothing else is shared.")
                }

                if !service.isBlocked(account) {
                    Section {
                        Toggle("Also block \(displayName)", isOn: $alsoBlock)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red).font(.footnote)
                    }
                }
            }
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button(alsoBlock && !service.isBlocked(account) ? "Report and Block" : "Report") { submit() }
                            .bold()
                            .disabled(details.count > 2000)
                    }
                }
            }
            .alert("Report Sent", isPresented: $sent) {
                Button("OK") { dismiss() }
            } message: {
                Text("Thanks for letting us know. The Relay team will review your report.")
            }
            .interactiveDismissDisabled(isSending)
        }
    }

    private func submit() {
        isSending = true
        errorMessage = nil
        let shouldBlock = alsoBlock && !service.isBlocked(account)
        Task {
            do {
                try await service.reportContact(
                    accountId: account,
                    reason: reason,
                    details: details,
                    includeRecentMessages: includeMessages
                )
                if shouldBlock { service.blockAccount(account) }
                sent = true
            } catch RelayAPIError.http(status: 429, _) {
                errorMessage = "You've sent a lot of reports today. Please try again tomorrow."
            } catch {
                errorMessage = FriendlyError.message(for: error)
            }
            isSending = false
        }
    }
}

// MARK: - Disappearing messages picker

private struct DisappearingSheet: View {
    let service: MessagingService
    let conversationId: String

    @Environment(\.dismiss) private var dismiss
    @State private var seconds: Int64

    private static let options: [(label: String, value: Int64)] = [
        ("Off", 0),
        ("5 minutes", 5 * 60),
        ("1 hour", 60 * 60),
        ("8 hours", 8 * 60 * 60),
        ("1 day", 24 * 60 * 60),
        ("1 week", 7 * 24 * 60 * 60),
        ("30 days", 30 * 24 * 60 * 60),
    ]

    init(service: MessagingService, conversationId: String) {
        self.service = service
        self.conversationId = conversationId
        let conv = service.conversations.first { $0.id == conversationId }
        _seconds = State(initialValue: conv?.disappearingSeconds ?? 0)
    }

    var body: some View {
        List(Self.options, id: \.value) { option in
            Button {
                seconds = option.value
                service.setDisappearingSeconds(conversationId, seconds: option.value)
                dismiss()
            } label: {
                HStack {
                    Text(option.label).foregroundStyle(.primary)
                    Spacer()
                    if seconds == option.value {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
            }
            .tint(.primary)
        }
        .navigationTitle("Disappearing Messages")
        .navigationBarTitleDisplayMode(.inline)
    }
}
