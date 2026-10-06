//
//  ConversationListView.swift
//  Relay
//

import Contacts
import MessageUI
import RelayKit
import SecureStorage
import SwiftUI
import UIKit

struct ConversationListView: View {
    let service: MessagingService

    @Environment(AppModel.self) private var model
    @Environment(ChatAppearance.self) private var appearance
    @State private var showingNewChatSheet = false
    @State private var showingNewGroup = false
    @State private var selectedConversationId: String?
    @State private var searchText = ""
    @State private var showingQRScanner = false
    @State private var panicMode = PanicModeManager.shared
    @State private var showingPanicPIN = false
    @State private var panicPINInput = ""
    @State private var mutingConversationId: String?
    @State private var conversationToDelete: String?
    @State private var isEditing = false
    @State private var selectedIds: Set<String> = []
    @State private var activeLabel: String? = nil  // nil = All
    // Kept as @State so the DB query only runs when searchText changes, not on every render.
    @State private var searchResults: [MessageStore.SearchResult] = []
    // Conversations successfully unlocked via Face ID this session.
    // Without this, setting selectedConversationId back after auth triggers
    // onChange again, re-prompting indefinitely.
    @State private var sessionUnlocked: Set<String> = []
    @State private var showingPanicPINError = false
    @State private var panicLockoutUntil: Date?
    @State private var qrStartError: String?
    @State private var confirmBulkDelete = false
    @State private var deleteError: String?
    /// Message to scroll to when a global-search message hit opens its chat.
    /// Hook for ChatView — see the detail column below. Survives the Face ID
    /// re-selection dance; cleared when a different chat is opened.
    @State private var searchTarget: (conversationId: String, messageId: String)?

    private static let availableLabels = ["Personal", "Work", "Family", "Unread", "Groups"]

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleConversations: [Conversation] {
        service.conversations.filter { c in
            guard !panicMode.isHidden(c.id) && !c.archived else { return false }
            guard let filter = activeLabel else { return true }
            switch filter {
            case "Unread": return c.unreadCount > 0
            case "Groups": return c.isGroup
            default: return c.label == filter
            }
        }
    }

    private var archivedConversations: [Conversation] {
        service.conversations.filter { $0.archived && !panicMode.isHidden($0.id) }
    }

    private var usedLabels: [String] {
        let all = service.conversations.filter { !$0.archived }
        var result = [String]()
        for label in Self.availableLabels {
            switch label {
            case "Unread":
                if all.contains(where: { $0.unreadCount > 0 }) { result.append(label) }
            case "Groups":
                if all.contains(where: { $0.isGroup }) { result.append(label) }
            default:
                if all.contains(where: { $0.label == label }) { result.append(label) }
            }
        }
        return result
    }

    var body: some View {
        NavigationSplitView {
            Group {
                if isSearching {
                    searchList
                } else {
                    conversationList
                }
            }
            .navigationTitle("Chats")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search messages").incognitoKeyboard()
            .onAppear {
                // Handle notification taps that arrived while this view was off-screen
                // (e.g. user was on a different tab when the notification fired).
                if let id = model.pendingNotificationConversationId {
                    model.pendingNotificationConversationId = nil
                    openConversation(id)
                }
            }
            .onChange(of: model.pendingNotificationConversationId) { _, id in
                guard let id else { return }
                model.pendingNotificationConversationId = nil
                openConversation(id)
            }
            .onChange(of: searchText) { _, query in
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                searchResults = trimmed.isEmpty ? [] : service.searchMessages(query: trimmed)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if isEditing {
                        Button("Done") {
                            isEditing = false
                            selectedIds = []
                        }
                    } else {
                        Button { showingNewChatSheet = true } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .accessibilityLabel("New Chat")
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    if panicMode.isEnabled {
                        Button {
                            if panicMode.isActive {
                                panicMode.deactivate()
                            } else {
                                panicPINInput = ""
                                showingPanicPIN = true
                            }
                        } label: {
                            Image(systemName: panicMode.isActive ? "lock.open.fill" : "lock.fill")
                                .foregroundStyle(panicMode.isActive ? .orange : .secondary)
                        }
                        .accessibilityLabel(panicMode.isActive ? "Lock chats" : "Unlock chats")
                    }
                    ConnectionBadge(state: service.connectionState)
                }
            }
            .confirmationDialog("Mute notifications for…", isPresented: Binding(
                get: { mutingConversationId != nil },
                set: { if !$0 { mutingConversationId = nil } }
            ), titleVisibility: .visible, presenting: mutingConversationId) { id in
                Button("1 Hour")  { service.setMuteDuration(id, seconds: 3600) }
                Button("8 Hours") { service.setMuteDuration(id, seconds: 8 * 3600) }
                Button("1 Week")  { service.setMuteDuration(id, seconds: 7 * 24 * 3600) }
                Button("Forever") { service.setMuteDuration(id, seconds: -1) }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(deleteDialogTitle, isPresented: Binding(
                get: { conversationToDelete != nil },
                set: { if !$0 { conversationToDelete = nil } }
            ), titleVisibility: .visible, presenting: conversationToDelete) { id in
                if let groupId = activeGroupId(for: id) {
                    Button("Leave Group & Delete", role: .destructive) {
                        leaveAndDelete(conversationId: id, groupId: groupId)
                    }
                    Button("Delete for Me", role: .destructive) {
                        service.deleteConversation(id)
                    }
                } else {
                    Button("Delete", role: .destructive) {
                        service.deleteConversation(id)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { id in
                if activeGroupId(for: id) != nil {
                    Text("“Delete for Me” removes the chat from this device but keeps you in the group.")
                }
            }
            .confirmationDialog(
                "Delete \(selectedIds.count) \(selectedIds.count == 1 ? "chat" : "chats")?",
                isPresented: $confirmBulkDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    service.bulkDelete(selectedIds)
                    finishEditing()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Messages in these chats will be removed from this device.")
            }
            .alert("Enter Panic PIN", isPresented: $showingPanicPIN) {
                SecureField("PIN", text: $panicPINInput)
                    .keyboardType(.numberPad)
                Button("Unlock") {
                    let pin = panicPINInput
                    panicPINInput = ""
                    Task {
                        let result = await panicMode.activate(pin: pin)
                        guard result != .unlocked else { return }
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                        if case .lockedOut(let until) = result {
                            panicLockoutUntil = until
                        } else {
                            panicLockoutUntil = nil
                        }
                        // Let the PIN alert finish dismissing before presenting the next one.
                        try? await Task.sleep(for: .milliseconds(350))
                        showingPanicPINError = true
                    }
                }
                Button("Cancel", role: .cancel) { panicPINInput = "" }
            }
            .alert(panicLockoutUntil == nil ? "Incorrect PIN" : "Too Many Attempts", isPresented: $showingPanicPINError) {
                if panicLockoutUntil == nil {
                    Button("Try Again") {
                        panicPINInput = ""
                        showingPanicPIN = true
                    }
                }
                Button(panicLockoutUntil == nil ? "Cancel" : "OK", role: .cancel) {}
            } message: {
                if let until = panicLockoutUntil {
                    Text("Try again \(until, format: .relative(presentation: .named)).")
                }
            }
            .alert("Couldn't Start Chat", isPresented: Binding(
                get: { qrStartError != nil },
                set: { if !$0 { qrStartError = nil } }
            )) {
                Button("OK", role: .cancel) { qrStartError = nil }
            } message: {
                Text(qrStartError ?? "")
            }
            .alert("Couldn't Leave Group", isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            )) {
                Button("OK", role: .cancel) { deleteError = nil }
            } message: {
                Text(deleteError ?? "")
            }
            .sheet(isPresented: $showingNewGroup) {
                NewGroupView(service: service) { conversationId in
                    openConversation(conversationId)
                }
            }
            .fullScreenCover(isPresented: $showingQRScanner) {
                ContactQRScanner { username in
                    showingQRScanner = false
                    Task {
                        do {
                            let conversationId = try await service.startConversation(username: username)
                            openConversation(conversationId)
                        } catch RelayAPIError.http(status: 404, _) {
                            qrStartError = "Couldn't find that user on Relay."
                        } catch {
                            qrStartError = "Couldn't reach Relay: \(error.localizedDescription)"
                        }
                    }
                }
            }
            .sheet(isPresented: $showingNewChatSheet) {
                NewChatSheet(service: service) { convId in
                    openConversation(convId)
                } onNewGroup: {
                    showingNewGroup = true
                } onQRScan: {
                    showingQRScanner = true
                } onSelectChats: {
                    isEditing = true
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isEditing && !selectedIds.isEmpty {
                    conversationSelectionBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.22), value: selectedIds.count)
            .navigationSplitViewColumnWidth(min: 300, ideal: 360)
        } detail: {
            if let conversationId = selectedConversationId {
                // A global search hit lands on the matched message.
                ChatView(
                    service: service, conversationId: conversationId,
                    onClose: { selectedConversationId = nil },
                    initialMessageId: searchTarget?.conversationId == conversationId ? searchTarget?.messageId : nil
                )
                    .id(conversationId)
            } else {
                ContentUnavailableView(
                    "Select a Chat",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Choose a conversation from the list.")
                )
            }
        }
        .onChange(of: selectedConversationId) { oldId, newId in
            // Drive conversation open/close here so it fires reliably regardless of
            // NavigationSplitView lifecycle ordering on compact (iPhone) mode.
            if let oldId, oldId != newId { service.closeConversation(id: oldId) }
            if let newId, searchTarget?.conversationId != newId { searchTarget = nil }
            if let newId { service.openConversation(newId) }

            // Re-lock when navigating back to the list.
            if newId == nil, let oldId { sessionUnlocked.remove(oldId) }
            guard let newId else { return }
            searchText = ""
            guard let conv = service.conversations.first(where: { $0.id == newId }),
                  conv.requireBiometricChat,
                  !sessionUnlocked.contains(newId) else { return }
            // Immediately hide the chat so content isn't visible during auth.
            selectedConversationId = nil
            Task {
                guard await BiometricGate.authenticate(reason: "Unlock this chat in Relay.") else { return }
                // Mark unlocked before setting the id so the re-triggered onChange skips auth.
                sessionUnlocked.insert(newId)
                selectedConversationId = newId
            }
        }
    }

    private var labelChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.sm) {
                Pill(title: "All", isSelected: activeLabel == nil) { activeLabel = nil }
                ForEach(usedLabels, id: \.self) { label in
                    Pill(title: label, isSelected: activeLabel == label) {
                        activeLabel = (activeLabel == label) ? nil : label
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.sm)
        }
    }

    private var conversationSelectionBar: some View {
        GlassContainer {
            HStack(spacing: 10) {
                Button { finishEditing() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 38, height: 38)
                        .glassCompat(in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Done selecting")

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(selectedIds.count) selected")
                        .font(.subheadline.weight(.semibold))
                        .contentTransition(.numericText())
                    Text("Manage chats")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)

                Spacer(minLength: 0)
                conversationSelectionButton("checkmark.circle", label: "Read") {
                    service.bulkMarkRead(selectedIds)
                    finishEditing()
                }
                conversationSelectionButton("bell.slash", label: "Mute") {
                    service.bulkMute(selectedIds)
                    finishEditing()
                }
                conversationSelectionButton("archivebox", label: "Archive") {
                    service.bulkArchive(selectedIds)
                    finishEditing()
                }
                conversationSelectionButton("trash", label: "Delete", role: .destructive) {
                    confirmBulkDelete = true
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassCompat(in: .rect(cornerRadius: 24))
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
    }

    private func conversationSelectionButton(
        _ systemName: String,
        label: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                Text(label)
                    .font(.caption2)
            }
            .foregroundStyle(role == .destructive ? Color.red : Color.primary)
            .frame(width: 48)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func finishEditing() {
        isEditing = false
        selectedIds = []
    }

    private var conversationList: some View {
        // Use List(selection:) so NavigationSplitView compact mode (iPhone)
        // automatically pushes to the detail column when a row is tapped.
        List(selection: Binding(
                get: { isEditing ? nil : selectedConversationId },
                set: { if !isEditing { selectedConversationId = $0 } }
            )) {
            if !usedLabels.isEmpty || activeLabel != nil {
                labelChips
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }

            if visibleConversations.isEmpty {
                ContentUnavailableView(
                    "No Conversations",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(activeLabel != nil ? "No chats match this filter." : "Start a conversation using the compose button.")
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            ForEach(visibleConversations) { conversation in
                if isEditing {
                    Button {
                        if selectedIds.contains(conversation.id) {
                            selectedIds.remove(conversation.id)
                        } else {
                            selectedIds.insert(conversation.id)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedIds.contains(conversation.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedIds.contains(conversation.id) ? Color.accentColor : Color.secondary)
                                .font(.title3)
                                .frame(width: 30, height: 30)
                                .contentTransition(.symbolEffect(.replace))
                            ConversationRow(conversation: conversation, service: service)
                        }
                        .padding(.vertical, 2)
                        .background {
                            if selectedIds.contains(conversation.id) {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.10))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .tag(conversation.id as String?)
                } else {
                ConversationRow(conversation: conversation, service: service)
                .tag(conversation.id as String?)
                .selectionDisabled()
                .onTapGesture { selectedConversationId = conversation.id }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        service.setConversationPinned(conversation.id, pinned: !conversation.isPinned)
                    } label: {
                        Label(conversation.isPinned ? "Unpin" : "Pin", systemImage: conversation.isPinned ? "pin.slash" : "pin.fill")
                    }
                    .tint(.orange)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        conversationToDelete = conversation.id
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    if conversation.unreadCount > 0 {
                        Button {
                            service.markConversationRead(conversation.id)
                        } label: {
                            Label("Read", systemImage: "checkmark.circle")
                        }
                        .tint(.blue)
                    } else {
                        Button {
                            service.markConversationUnread(conversation.id)
                        } label: {
                            Label("Unread", systemImage: "envelope.badge")
                        }
                        .tint(.blue)
                    }
                    Button {
                        if service.isConversationMuted(conversation.id) {
                            service.setConversationMuted(conversation.id, muted: false)
                        } else {
                            mutingConversationId = conversation.id
                        }
                    } label: {
                        let muted = service.isConversationMuted(conversation.id)
                        Label(muted ? "Unmute" : "Mute", systemImage: muted ? "bell" : "bell.slash")
                    }
                    .tint(.gray)
                    Button {
                        service.setConversationArchived(conversation.id, archived: true)
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    .tint(.gray)
                }
                .listRowSeparator(.hidden)
                .listRowBackground(
                    conversation.isPinned
                        ? RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.orange.opacity(0.07))
                            .padding(.horizontal, 8)
                        : nil
                )
                .contextMenu {
                    if panicMode.isEnabled {
                        Button {
                            panicMode.hide(conversation.id)
                            SpotlightIndexer.deindex(conversationId: conversation.id)
                            ShareBridge.removeConversation(conversation.id)
                        } label: {
                            Label("Hide in Panic Mode", systemImage: "eye.slash")
                        }
                    }
                    Menu("Label") {
                        Button("None") { service.setConversationLabel(conversation.id, label: nil) }
                        ForEach(["Personal", "Work", "Family"], id: \.self) { label in
                            Button(label) { service.setConversationLabel(conversation.id, label: label) }
                        }
                    }
                }
                } // end else (not editing)
            } // end ForEach

            if !isEditing && !archivedConversations.isEmpty {
                NavigationLink(destination: ArchivedChatsView(service: service, selectedConversationId: $selectedConversationId)) {
                    HStack {
                        Label("Archived Chats", systemImage: "archivebox")
                            .foregroundStyle(.secondary)
                        Spacer()
                        CountBadge(count: archivedConversations.count, tint: .secondary.opacity(0.6))
                    }
                }
                .listRowSeparator(.hidden)
            }
        } // end List
        .listStyle(.plain)
    }

    private var searchList: some View {
        List(selection: Binding(
            get: { selectedConversationId },
            set: { selectedConversationId = $0 }
        )) {
            // Panic-hidden chats must never surface through search.
            let matchingConversations = service.conversations.filter { conversation in
                !panicMode.isHidden(conversation.id)
                    && displayName(for: conversation).localizedCaseInsensitiveContains(searchText)
            }
            let messageResults = searchResults.filter { !panicMode.isHidden($0.conversationId) }
            if !matchingConversations.isEmpty {
                Section("Conversations") {
                    ForEach(matchingConversations) { conversation in
                        ConversationRow(conversation: conversation, service: service)
                            .tag(conversation.id as String?)
                    }
                }
            }
            if !messageResults.isEmpty {
                Section("Messages") {
                    ForEach(messageResults) { result in
                        Button {
                            searchTarget = (result.conversationId, result.messageId)
                            openConversation(result.conversationId)
                        } label: {
                            SearchResultRow(result: result, service: service, query: searchText)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if matchingConversations.isEmpty && messageResults.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .listStyle(.plain)
    }

    private func displayName(for conversation: Conversation) -> String {
        if conversation.isGroup { return conversation.peerUsername ?? "Group" }
        return service.displayName(forAccount: conversation.peerAccount)
    }

    private func openConversation(_ conversationId: String) {
        selectedConversationId = conversationId
        // onChange(of: selectedConversationId) handles biometric check and searchText clearing
    }

    private var deleteDialogTitle: String {
        guard let id = conversationToDelete, activeGroupId(for: id) != nil else {
            return "Delete this conversation?"
        }
        return "Delete this group chat?"
    }

    /// The group id when `conversationId` is a group we're still a member of
    /// (so "Leave Group" makes sense); nil for 1:1 chats or groups already left.
    private func activeGroupId(for conversationId: String) -> String? {
        guard let group = service.group(for: conversationId),
              group.members.contains(service.credentials.accountId) else { return nil }
        return group.id
    }

    private func leaveAndDelete(conversationId: String, groupId: String) {
        Task {
            do {
                try await service.leaveGroup(groupId)
                service.deleteConversation(conversationId)
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }

}

// MARK: - New Chat Sheet

private struct NewChatSheet: View {
    let service: MessagingService
    let onConversationStarted: (String) -> Void
    let onNewGroup: () -> Void
    let onQRScan: () -> Void
    let onSelectChats: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var contacts: [ContactEntry] = []
    @State private var authDenied = false
    @State private var isLoadingContacts = false
    /// The user tapped "Find contacts on Relay" (and has consented).
    @State private var discoveryStarted = false
    @State private var showingDiscoveryConsent = false
    @State private var searchText = ""
    @State private var showingUsernameSearch = false
    @State private var startingContactEmail: String?
    @State private var invitePayload: InvitePayload?
    @State private var addError: String?
    /// Set when the "who's on Relay" lookup failed (503 / offline) — contacts
    /// are then shown without Invite buttons rather than all as "not on Relay".
    @State private var discoveryError: String?

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var filtered: [ContactEntry] {
        guard isSearching else { return contacts }
        let q = searchText.lowercased()
        return contacts.filter {
            $0.name.lowercased().contains(q) ||
            $0.emails.contains { $0.lowercased().contains(q) }
        }
    }

    /// Contacts grouped into alphabetical sections, sorted by display name.
    private var sections: [(letter: String, entries: [ContactEntry])] {
        var dict: [String: [ContactEntry]] = [:]
        for entry in contacts {
            let first = entry.name.first.map { String($0).uppercased() } ?? "#"
            let key = (first.first?.isLetter == true) ? first : "#"
            dict[key, default: []].append(entry)
        }
        return dict
            .map { (letter: $0.key, entries: $0.value) }
            .sorted { lhs, rhs in
                if lhs.letter == "#" { return false }
                if rhs.letter == "#" { return true }
                return lhs.letter < rhs.letter
            }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    // Quick-action rows
                    Section {
                        actionRow("Find by @username", icon: "magnifyingglass") { showingUsernameSearch = true }
                        actionRow("New Group", icon: "person.3") {
                            dismiss(); DispatchQueue.main.async { onNewGroup() }
                        }
                        actionRow("Note to Self", icon: "note.text") {
                            Task {
                                let id = await service.ensureNoteToSelf()
                                guard !id.isEmpty else { return }
                                dismiss(); DispatchQueue.main.async { onConversationStarted(id) }
                            }
                        }
                        actionRow("Scan QR Code", icon: "qrcode.viewfinder") {
                            dismiss(); DispatchQueue.main.async { onQRScan() }
                        }
                    }

                    // Contact sections — only after the user explicitly asks.
                    if !discoveryStarted {
                        Section {
                            Button {
                                requestContactDiscovery()
                            } label: {
                                Label("Find contacts on Relay", systemImage: "person.crop.circle.badge.checkmark")
                            }
                        } footer: {
                            Text(ContactDiscoveryConsent.explanation)
                        }
                    } else if authDenied {
                        Section {
                            Label("Allow Contacts access in Settings → Relay to see who's on Relay.", systemImage: "person.slash")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                        }
                    } else if isLoadingContacts {
                        Section {
                            HStack { Spacer(); ProgressView("Checking contacts…"); Spacer() }
                                .listRowSeparator(.hidden)
                        }
                    } else if isSearching {
                        if let discoveryError { discoveryErrorSection(discoveryError) }
                        if filtered.isEmpty {
                            Section {
                                Text("No results for \"\(searchText)\".")
                                    .foregroundStyle(.secondary).font(.subheadline)
                            }
                        } else {
                            Section {
                                ForEach(filtered) { entry in contactRow(entry) }
                            }
                        }
                    } else {
                        if let discoveryError { discoveryErrorSection(discoveryError) }
                        ForEach(sections, id: \.letter) { section in
                            Section(header: Text(section.letter).font(.subheadline.weight(.semibold))) {
                                ForEach(section.entries) { entry in contactRow(entry) }
                            }
                            .id(section.letter)
                        }
                    }
                }
                .listStyle(.plain)
                .overlay(alignment: .trailing) {
                    if !isLoadingContacts && !authDenied && !isSearching && !sections.isEmpty {
                        AlphabetScrubber(letters: sections.map(\.letter)) { letter in
                            withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(letter, anchor: .top) }
                        }
                        .padding(.trailing, 4)
                        // Section headers already give VoiceOver users the index.
                        .accessibilityHidden(true)
                    }
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search contacts").incognitoKeyboard()
            .navigationTitle("New Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showingUsernameSearch) { usernameSearchSheet }
            .sheet(item: $invitePayload) { payload in
                MessageComposeView(recipients: payload.recipients, body: payload.body)
                    .ignoresSafeArea()
            }
            .alert("Couldn't Start Chat", isPresented: Binding(
                get: { addError != nil },
                set: { if !$0 { addError = nil } }
            )) {
                Button("OK", role: .cancel) { addError = nil }
            } message: {
                Text(addError ?? "")
            }
            .alert("Find Contacts on Relay?", isPresented: $showingDiscoveryConsent) {
                Button("Find Contacts") {
                    ContactDiscoveryConsent.grant()
                    startContactDiscovery()
                }
                Button("Not Now", role: .cancel) {}
            } message: {
                Text(ContactDiscoveryConsent.explanation)
            }
        }
        // No automatic contact access or lookup: see requestContactDiscovery().
    }

    /// Contact discovery runs only when the user taps "Find contacts on Relay".
    /// The first time, they see what it does and must agree; the agreement is
    /// remembered so later taps go straight to the lookup.
    private func requestContactDiscovery() {
        if ContactDiscoveryConsent.isGranted {
            startContactDiscovery()
        } else {
            showingDiscoveryConsent = true
        }
    }

    private func startContactDiscovery() {
        discoveryStarted = true
        isLoadingContacts = true
        Task { await loadContacts() }
    }

    @ViewBuilder
    private func discoveryErrorSection(_ message: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("Couldn't check which contacts are on Relay", systemImage: "exclamationmark.triangle")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Retry") { Task { await checkRelayStatus() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func actionRow(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
        }
    }

    @ViewBuilder
    private func contactRow(_ entry: ContactEntry) -> some View {
        ContactRow(
            entry: entry,
            startingEmail: $startingContactEmail,
            onAdd: { startContact(email: $0) },
            onInvite: { entry in
                invitePayload = InvitePayload(
                    recipients: entry.messageRecipients,
                    body: "Hey \(entry.name), join me on Relay — a private, encrypted messenger. Download it at https://relaymsg.app"
                )
            }
        )
    }

    @ViewBuilder
    private var usernameSearchSheet: some View {
        UsernameSearchSheet(service: service) { convId in
            showingUsernameSearch = false
            dismiss()
            onConversationStarted(convId)
        } onDismiss: {
            showingUsernameSearch = false
        }
    }

    private func startContact(email: String) {
        guard startingContactEmail == nil else { return }
        startingContactEmail = email
        Task {
            do {
                let convId = try await service.startConversation(username: email)
                startingContactEmail = nil
                dismiss()
                onConversationStarted(convId)
            } catch {
                startingContactEmail = nil
                addError = error.localizedDescription
            }
        }
    }

    private func loadContacts() async {
        let store = CNContactStore()
        let auth = CNContactStore.authorizationStatus(for: .contacts)
        if auth == .notDetermined {
            guard (try? await store.requestAccess(for: .contacts)) == true else {
                await MainActor.run { authDenied = true; isLoadingContacts = false }
                return
            }
        } else if auth == .denied || auth == .restricted {
            await MainActor.run { authDenied = true; isLoadingContacts = false }
            return
        }

        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey,
                    CNContactEmailAddressesKey, CNContactPhoneNumbersKey,
                    CNContactThumbnailImageDataKey,
                    CNContactImageDataAvailableKey] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .givenName

        var raw: [(name: String, emails: [String], phones: [String], avatar: Data?)] = []
        try? store.enumerateContacts(with: request) { contact, _ in
            let emails = contact.emailAddresses.map { ($0.value as String).lowercased().trimmingCharacters(in: .whitespaces) }
            let phones = contact.phoneNumbers.map { $0.value.stringValue }
            guard !emails.isEmpty || !phones.isEmpty else { return }
            let name = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
            let avatar = contact.imageDataAvailable ? contact.thumbnailImageData : nil
            raw.append((name: name.isEmpty ? (emails.first ?? phones.first ?? "") : name,
                        emails: emails, phones: phones, avatar: avatar))
        }

        // Deduplicate: if two contacts share an email, only keep the first.
        var seen = Set<String>()
        let deduped = raw.filter { entry in
            let keys = entry.emails + entry.phones
            let isNew = !keys.contains(where: { seen.contains($0) })
            if isNew { keys.forEach { seen.insert($0) } }
            return isNew
        }

        let entries = deduped.map { ContactEntry(name: $0.name, emails: $0.emails, phones: $0.phones, avatar: $0.avatar) }
        contacts = entries
        isLoadingContacts = false
        await checkRelayStatus()
    }

    /// Privately matches every contact email against the directory in one
    /// blinded batch. A lookup failure (503 / offline) is surfaced as an error
    /// with Retry — never as "not on Relay", which would offer Invite to
    /// people who are already here.
    private func checkRelayStatus() async {
        discoveryError = nil
        for i in contacts.indices { contacts[i].relayStatus = .checking }
        let emails = contacts.flatMap(\.emails)
        guard !emails.isEmpty else {
            for i in contacts.indices { contacts[i].relayStatus = .notOnRelay }
            return
        }
        do {
            let matches = try await service.discoverContacts(emails: emails)
            let matched = Set(matches.map { $0.email })
            for i in contacts.indices {
                if let email = contacts[i].emails.first(where: { matched.contains($0) }) {
                    contacts[i].relayStatus = .onRelay(email: email)
                } else {
                    contacts[i].relayStatus = .notOnRelay
                }
            }
        } catch {
            for i in contacts.indices { contacts[i].relayStatus = .unknown }
            discoveryError = error.localizedDescription
        }
    }
}

private struct ContactEntry: Identifiable {
    let id = UUID()
    let name: String
    let emails: [String]
    let phones: [String]
    let avatar: Data?
    var relayStatus: RelayStatus = .checking

    // Preferred recipients for iMessage: phone numbers first, then emails.
    var messageRecipients: [String] { phones.isEmpty ? emails : phones }

    enum RelayStatus {
        case checking
        case onRelay(email: String)
        case notOnRelay
        /// The lookup failed; we don't know (no Add, no Invite).
        case unknown
    }
}

private struct InvitePayload: Identifiable {
    let id = UUID()
    let recipients: [String]
    let body: String
}

private struct ContactRow: View {
    let entry: ContactEntry
    @Binding var startingEmail: String?
    let onAdd: (String) -> Void
    let onInvite: (ContactEntry) -> Void

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(name: entry.name, size: 28, imageData: entry.avatar)
            Text(entry.name)
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 4)
            actionButton
        }
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 28))
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var actionButton: some View {
        switch entry.relayStatus {
        case .checking:
            ProgressView().controlSize(.mini)
        case .onRelay(let email):
            let busy = startingEmail == email
            Button { onAdd(email) } label: {
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Text("Add").fontWeight(.semibold)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
            .disabled(busy)
        case .notOnRelay:
            Button { onInvite(entry) } label: {
                Text("Invite")
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .tint(.secondary)
        case .unknown:
            EmptyView()
        }
    }
}

private struct AlphabetScrubber: View {
    let letters: [String]
    let onSelect: (String) -> Void

    private let itemHeight: CGFloat = 15

    var body: some View {
        VStack(spacing: 1) {
            ForEach(letters, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16, height: itemHeight)
            }
        }
        .padding(.vertical, 4)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    let index = Int((value.location.y - 4) / (itemHeight + 1))
                    let clamped = max(0, min(index, letters.count - 1))
                    onSelect(letters[clamped])
                }
        )
    }
}

private struct MessageComposeView: UIViewControllerRepresentable {
    let recipients: [String]
    let body: String

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.recipients = recipients
        vc.body = body
        vc.messageComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uvc: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let dismiss: DismissAction
        init(dismiss: DismissAction) { self.dismiss = dismiss }
        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            dismiss()
        }
    }
}

// MARK: - Username search sheet

private struct UsernameSearchSheet: View {
    let service: MessagingService
    let onConversationStarted: (String) -> Void
    let onDismiss: () -> Void

    enum LookupState: Equatable {
        case idle, searching, found(accountId: String, username: String), notFound, error(String)
    }

    @State private var query = ""
    @State private var lookupState: LookupState = .idle
    @State private var lookupTask: Task<Void, Never>?
    @State private var isStarting = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("@")
                            .foregroundStyle(.secondary)
                            .font(.body.weight(.semibold))
                        TextField("username", text: $query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: query) { _, new in scheduleSearch(new) }
                    }
                } footer: {
                    Text("Search for someone by their @username.")
                        .font(.footnote)
                }

                switch lookupState {
                case .idle:
                    EmptyView()
                case .searching:
                    Section {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                case .found(let accountId, let username):
                    Section("Result") {
                        HStack(spacing: 14) {
                            AvatarView(name: username, size: 44, imageData: nil)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("@\(username)").font(.body.weight(.medium))
                                Text(accountId.prefix(8)).font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if isStarting {
                                ProgressView()
                            } else {
                                Button("Message") { startConversation(username: username) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }
                case .notFound:
                    Section {
                        Text("No user found for @\(query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                case .error(let msg):
                    Section {
                        Label(msg, systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Find by @username")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
            }
        }
    }

    private func scheduleSearch(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        lookupTask?.cancel()
        guard q.count >= 2 else { lookupState = .idle; return }
        lookupState = .searching
        lookupTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            do {
                let accountId = try await service.resolveAccount(username: q)
                guard !Task.isCancelled else { return }
                lookupState = .found(accountId: accountId, username: q)
            } catch RelayAPIError.http(status: 404, _) {
                guard !Task.isCancelled else { return }
                lookupState = .notFound
            } catch {
                guard !Task.isCancelled else { return }
                lookupState = .error(error.localizedDescription)
            }
        }
    }

    private func startConversation(username: String) {
        isStarting = true
        Task {
            do {
                let convId = try await service.startConversation(username: username)
                isStarting = false
                onConversationStarted(convId)
            } catch {
                isStarting = false
                lookupState = .error("Couldn't start conversation: \(error.localizedDescription)")
            }
        }
    }
}

private struct ConversationRow: View {
    let conversation: Conversation
    let service: MessagingService

    private var isRelayOfficial: Bool { conversation.peerAccount == service.relayOfficialAccount }

    private var displayName: String {
        if isRelayOfficial { return "Relay" }
        if conversation.peerAccount == service.noteToSelfAccount { return "Note to Self" }
        if conversation.isGroup { return conversation.peerUsername ?? "Group" }
        return service.displayName(forAccount: conversation.peerAccount)
    }

    private var avatarData: Data? {
        if conversation.peerAccount == service.noteToSelfAccount { return nil }
        if conversation.isGroup { return service.group(for: conversation.id)?.avatarData }
        return service.peerAvatarData(forAccount: conversation.peerAccount)
    }


    private var isBlocked: Bool {
        !conversation.isGroup && service.isBlocked(conversation.peerAccount)
    }

    private var lastMessagePreview: (symbol: String?, text: String) {
        if isBlocked { return (nil, "Blocked") }
        if conversation.hidePreviews { return (nil, "Preview hidden") }
        let draft = service.readDraft(for: conversation.id)
        if !draft.isEmpty { return ("pencil", "Draft: \(draft)") }
        let isNoteToSelf = conversation.peerAccount == service.noteToSelfAccount
        let prefix = conversation.lastMessageIsOutgoing && !isNoteToSelf ? "You: " : ""
        switch conversation.lastMessageBody {
        case "~loc~":   return ("location.fill", "\(prefix)Location")
        case "~photo~": return ("photo.fill", "\(prefix)Photo")
        case "~audio~": return ("waveform", "\(prefix)Voice note")
        case "~file~":  return ("paperclip", "\(prefix)Attachment")
        case let body where body?.hasPrefix("call:") == true:
            return ("phone.fill", String((body ?? "").dropFirst(5)))
        case let body:
            let fallback = isNoteToSelf ? "Tap to write a note" : "No messages yet"
            return (nil, body.map { "\(prefix)\($0)" } ?? fallback)
        }
    }

    private var hasDraft: Bool {
        !service.readDraft(for: conversation.id).isEmpty
    }

    private var hasUnread: Bool { conversation.unreadCount > 0 }
    private var isMuted: Bool { service.isConversationMuted(conversation.id) }

    private var lastMessageStatusSymbol: String? {
        switch conversation.lastMessageStatus {
        case .sending:   "clock"
        case .sent:      "checkmark"
        case .delivered: "checkmark.circle"
        case .read:      "checkmark.circle.fill"
        case .failed:    "exclamationmark.circle"
        default:         nil
        }
    }

    @ViewBuilder
    private var deliveryStatusIcon: some View {
        if let symbol = lastMessageStatusSymbol {
            let status = conversation.lastMessageStatus
            Image(systemName: symbol)
                .font(.system(
                    size: status == .sent ? 10 : 11,
                    weight: status == .sent ? .semibold : .regular
                ))
                .foregroundStyle(
                    status == .read   ? AnyShapeStyle(.tint) :
                    status == .failed ? AnyShapeStyle(.red)  :
                    status == .delivered ? AnyShapeStyle(.secondary) :
                    AnyShapeStyle(.tertiary)
                )
                .contentTransition(.symbolEffect(.replace))
        }
    }

    var body: some View {
        HStack(spacing: 13) {
            if isRelayOfficial {
                RelayOfficialAvatar(size: 54)
            } else if conversation.peerAccount == service.noteToSelfAccount {
                ZStack {
                    Circle()
                        .fill(Color.yellow.opacity(0.18))
                        .frame(width: 54, height: 54)
                    Image(systemName: "note.text")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.yellow)
                }
            } else {
            AvatarView(name: displayName, size: 54, imageData: avatarData)
                .overlay(alignment: .bottomTrailing) {
                    if conversation.isGroup {
                        Image(systemName: "person.3.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Color.secondary.opacity(0.8), in: .circle)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                // — Name row —
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    HStack(spacing: 4) {
                        if conversation.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        if isBlocked {
                            Image(systemName: "nosign")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                        Text(displayName)
                            .font(hasUnread ? .headline.weight(.bold) : .headline)
                            .lineLimit(1)
                        if isRelayOfficial {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                                .accessibilityLabel("Official")
                        }
                    }
                    Spacer(minLength: 6)
                    HStack(spacing: 5) {
                        if isMuted {
                            Image(systemName: "bell.slash.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        if conversation.lastMessageIsOutgoing && !conversation.isGroup {
                            deliveryStatusIcon
                        }
                        if let ts = conversation.lastMessageAt {
                            Text(Self.relativeLabel(ts))
                                .font(hasUnread ? .caption.weight(.semibold) : .caption)
                                .foregroundStyle(hasUnread ? .primary : .secondary)
                        }
                    }
                    .animation(.spring(duration: 0.35), value: lastMessageStatusSymbol)
                }

                // — Preview row —
                HStack(spacing: 0) {
                    let isTypingHere = service.typingConversations.contains(conversation.id)
                    let preview = lastMessagePreview
                    let previewStyle: AnyShapeStyle = isBlocked   ? AnyShapeStyle(.red.opacity(0.7)) :
                                                      isTypingHere ? AnyShapeStyle(.teal) :
                                                      hasDraft    ? AnyShapeStyle(.orange) :
                                                      hasUnread   ? AnyShapeStyle(.primary.opacity(0.75)) :
                                                                    AnyShapeStyle(.secondary)
                    Group {
                        if isTypingHere {
                            Label("Typing\u{2026}", systemImage: "ellipsis.bubble")
                        } else if let symbol = preview.symbol {
                            HStack(spacing: 4) {
                                Image(systemName: symbol)
                                Text(preview.text)
                            }
                        } else {
                            Text(preview.text)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(previewStyle)
                    .lineLimit(1)
                    Spacer(minLength: 6)
                    if hasUnread {
                        CountBadge(count: conversation.unreadCount)
                    }
                }
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .contentShape(.rect)
    }

    private static func relativeLabel(_ millis: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(millis) / 1000)
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if cal.isDateInYesterday(date) {
            return "Yesterday"
        }
        if let weekAgo = cal.date(byAdding: .day, value: -6, to: .now), date >= weekAgo {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

private struct SearchResultRow: View {
    let result: MessageStore.SearchResult
    let service: MessagingService
    var query: String = ""

    private var conversation: Conversation? {
        service.conversations.first { $0.id == result.conversationId }
    }

    private var title: String {
        guard let conversation else { return "Message" }
        if conversation.isGroup { return conversation.peerUsername ?? "Group" }
        return service.displayName(forAccount: conversation.peerAccount)
    }

    var body: some View {
        HStack(spacing: 12) {
            if let conv = conversation {
                AvatarView(
                    name: title,
                    size: 44,
                    imageData: conv.isGroup
                        ? service.group(for: conv.id)?.avatarData
                        : service.peerAvatarData(forAccount: conv.peerAccount)
                )
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                highlighted(text: result.body, query: query)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(relativeLabel(result.timestamp))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private func highlighted(text: String, query: String) -> Text {
        guard !query.isEmpty else {
            return Text(text).foregroundStyle(.secondary)
        }
        var result = Text("")
        var searchFrom = text.startIndex
        while searchFrom < text.endIndex {
            let remaining = text[searchFrom...]
            guard let matchRange = remaining.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
                result = result + Text(remaining).foregroundStyle(.secondary)
                break
            }
            if remaining.startIndex < matchRange.lowerBound {
                result = result + Text(remaining[remaining.startIndex..<matchRange.lowerBound]).foregroundStyle(.secondary)
            }
            result = result + Text(remaining[matchRange]).fontWeight(.semibold).foregroundStyle(.primary)
            searchFrom = matchRange.upperBound
        }
        return result
    }

    private func relativeLabel(_ millis: Int64) -> String {
        Date(timeIntervalSince1970: Double(millis) / 1000).formatted(date: .abbreviated, time: .shortened)
    }
}

private struct ArchivedChatsView: View {
    let service: MessagingService
    @Binding var selectedConversationId: String?
    @Environment(\.dismiss) private var dismiss

    private var archivedConversations: [Conversation] {
        service.conversations.filter { $0.archived && !PanicModeManager.shared.isHidden($0.id) }
    }

    var body: some View {
        List {
            if archivedConversations.isEmpty {
                ContentUnavailableView(
                    "No Archived Chats",
                    systemImage: "archivebox",
                    description: Text("Swipe left on a chat and tap Archive to move it here.")
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            ForEach(archivedConversations) { conversation in
                Button {
                    selectedConversationId = conversation.id
                    dismiss()
                } label: {
                    ConversationRow(conversation: conversation, service: service)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button {
                        service.setConversationArchived(conversation.id, archived: false)
                    } label: {
                        Label("Unarchive", systemImage: "archivebox.fill")
                    }
                    .tint(.blue)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Archived Chats")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: archivedConversations.isEmpty) { _, empty in
            if empty { dismiss() }
        }
    }
}

struct ConnectionBadge: View {
    let state: MessagingService.ConnectionState

    var body: some View {
        switch state {
        case .connected:
            EmptyView()
        case .connecting:
            ProgressView()
                .accessibilityLabel("Connecting…")
        case .disconnected:
            Image(systemName: "wifi.slash")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Offline")
        }
    }
}
