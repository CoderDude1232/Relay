//
//  ConversationListView.swift
//  Relay
//

import Contacts
import MessageUI
import RelayCore
import RelayKit
import SecureStorage
import SwiftUI
import UIKit

struct ConversationListView: View {
    let service: MessagingService

    @Environment(AppModel.self) private var model
    @Environment(ChatAppearance.self) private var appearance
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
    @State private var folderStore = ChatFolderStore.shared
    @State private var showingFolderManager = false
    @State private var showingRequests = false
    @State private var showingProxySettings = false
    /// Chat waiting to go into a folder created from its context menu.
    @State private var newFolderForConversation: String?
    @State private var newFolderName = ""
    // Kept as @State so the DB query only runs when searchText changes, not on every render.
    @State private var searchResults: [MessageStore.SearchResult] = []
    // Chats unlocked with Face ID this session. Restoring selectedConversationId
    // after auth re-fires onChange, which would otherwise prompt again.
    @State private var sessionUnlocked: Set<String> = []
    @State private var showingPanicPINError = false
    @State private var panicLockoutUntil: Date?
    @State private var qrStartError: String?
    @State private var confirmBulkDelete = false
    @State private var deleteError: String?
    /// Message to scroll to when a global-search hit opens its chat. Survives
    /// the Face ID re-selection; cleared when another chat is opened.
    @State private var searchTarget: (conversationId: String, messageId: String)?

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleConversations: [Conversation] {
        service.conversations.filter { c in
            guard !panicMode.isHidden(c.id) && !c.archived && !c.isRequest else { return false }
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

    /// Filter chips: the user's folders that hold chats (in their order), then
    /// the built-in Unread and Groups filters when they'd match anything.
    private var usedLabels: [String] {
        let all = service.conversations.filter { !$0.archived && !panicMode.isHidden($0.id) }
        var result = folderStore.folders.filter { folder in
            folder == activeLabel || all.contains { $0.label == folder }
        }
        if all.contains(where: { $0.unreadCount > 0 }) || activeLabel == "Unread" { result.append("Unread") }
        if all.contains(where: { $0.isGroup }) { result.append("Groups") }
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
                // Notification taps that arrived while this view was off-screen.
                if let id = model.pendingNotificationConversationId {
                    model.pendingNotificationConversationId = nil
                    openConversation(id)
                }
            }
            .onChange(of: model.pendingNotificationConversationId) { _, id in
                guard let id else { return }
                model.pendingNotificationConversationId = nil
                if selectedConversationId == id {
                    // Already open: selecting it again changes nothing, so
                    // load what arrived while we were away.
                    service.reloadActiveConversation()
                } else {
                    openConversation(id)
                }
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
            } message: { _ in
                Text("You'll still be notified when someone @mentions you.")
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
                    startConversationFromQR(username)
                }
            }
            .sheet(isPresented: $showingNewChatSheet) {
                NewChatSheet(service: service) { convId in
                    openConversation(convId)
                } onQRScanned: { username in
                    startConversationFromQR(username)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isEditing && !selectedIds.isEmpty {
                    conversationSelectionBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.22), value: selectedIds.count)
            .sidebarTabBar()
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
        .onChange(of: model.pendingScanQR) { _, requested in
            guard requested else { return }
            model.pendingScanQR = false
            showingQRScanner = true
        }
        .onAppear {
            if model.pendingScanQR {
                model.pendingScanQR = false
                showingQRScanner = true
            }
        }
        .onChange(of: panicMode.isActive) { _, active in
            // Locking (including from the Panic Mode control) closes a hidden chat.
            if !active, let id = selectedConversationId, panicMode.isHidden(id) {
                selectedConversationId = nil
            }
        }
        .onChange(of: selectedConversationId) { oldId, newId in
            // Open/close here: NavigationSplitView lifecycle ordering is
            // unreliable in compact mode.
            if let oldId, oldId != newId { service.closeConversation(id: oldId) }
            if let newId, searchTarget?.conversationId != newId { searchTarget = nil }

            // Re-lock when leaving a chat, whether to the list or another chat.
            if let oldId, oldId != newId { sessionUnlocked.remove(oldId) }
            guard let newId else { return }
            searchText = ""
            if let conv = service.conversations.first(where: { $0.id == newId }),
               conv.requireBiometricChat,
               !sessionUnlocked.contains(newId) {
                // Hide the chat while authenticating. It isn't opened (which
                // marks it read and sends read receipts) until unlocked.
                selectedConversationId = nil
                Task {
                    guard await BiometricGate.authenticate(reason: "Unlock this chat in Relay.") else { return }
                    // Mark unlocked before setting the id so the re-triggered onChange skips auth.
                    sessionUnlocked.insert(newId)
                    selectedConversationId = newId
                }
                return
            }
            service.openConversation(newId)
        }
    }

    private func requestLooksLikeScam(_ conversationId: String) -> Bool {
        _ = service.scamFlagsRevision
        return service.scamFlag(forConversation: conversationId) != nil
    }

    private func startConversationFromQR(_ username: String) {
        Task {
            do {
                let conversationId = try await service.startConversation(username: username)
                openConversation(conversationId)
            } catch RelayAPIError.http(status: 404, _) {
                qrStartError = "Couldn't find that user on Relay."
            } catch {
                qrStartError = FriendlyError.message(for: error)
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
                IconPill(systemImage: "plus") { showingFolderManager = true }
                    .accessibilityLabel("Add chat folder")
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

    /// Beside the open chat (iPad), its row stays highlighted; pinned chats
    /// keep their tint otherwise.
    @ViewBuilder
    private func rowBackground(for conversation: Conversation) -> some View {
        if horizontalSizeClass == .regular, !isEditing, conversation.id == selectedConversationId {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(0.14))
                .padding(.horizontal, 8)
        } else if conversation.isPinned {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.07))
                .padding(.horizontal, 8)
        } else {
            Color.clear
        }
    }

    private func finishEditing() {
        isEditing = false
        selectedIds = []
    }

    private var conversationList: some View {
        // List(selection:) makes compact NavigationSplitView push the detail
        // column on tap.
        List(selection: Binding(
                get: { isEditing ? nil : selectedConversationId },
                set: { if !isEditing { selectedConversationId = $0 } }
            )) {
            labelChips
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

            if service.isRestoringHistory {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Restoring your messages…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .listRowSeparator(.hidden)
                .accessibilityElement(children: .combine)
            }

            if let status = model.proxyStatus, status.isProblem, !isEditing {
                Button { showingProxySettings = true } label: {
                    HStack(spacing: 12) {
                        ProxyStatusRow(status: status)
                        Spacer(minLength: 0)
                        Text("Review").font(.subheadline.weight(.semibold))
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 14, style: .continuous))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .selectionDisabled()
                .listRowSeparator(.hidden)
                .accessibilityHint("Proxy problem. Opens proxy settings.")
            }

            let requests = service.messageRequests.filter { !panicMode.isHidden($0.id) }
            if activeLabel == nil, !isEditing, !requests.isEmpty {
                Button { showingRequests = true } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "tray.full.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 54, height: 54)
                            .background(Color.accentColor.gradient, in: .circle)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Message Requests").font(.headline)
                            Text(requests.count == 1 ? "1 person wants to message you" : "\(requests.count) people want to message you")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Text("\(requests.count)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.accentColor, in: .capsule)
                            .accessibilityHidden(true)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .selectionDisabled()
                .accessibilityElement(children: .combine)
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
                .accessibilityAddTraits(.isButton)
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
                .listRowBackground(rowBackground(for: conversation))
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
                    Menu {
                        ForEach(folderStore.folders, id: \.self) { folder in
                            Button {
                                service.setConversationLabel(conversation.id, label: folder)
                            } label: {
                                if conversation.label == folder {
                                    Label(folder, systemImage: "checkmark")
                                } else {
                                    Text(folder)
                                }
                            }
                        }
                        if conversation.label != nil {
                            Button("Remove from Folder") { service.setConversationLabel(conversation.id, label: nil) }
                        }
                        Divider()
                        Button {
                            newFolderName = ""
                            newFolderForConversation = conversation.id
                        } label: {
                            Label("New Folder…", systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Label("Move to Folder", systemImage: "folder")
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
        .navigationDestination(isPresented: $showingProxySettings) {
            ProxySettingsView()
        }
        .navigationDestination(isPresented: $showingRequests) {
                List {
                    Section {
                        ForEach(service.messageRequests.filter { !panicMode.isHidden($0.id) }) { request in
                            Button {
                                // Back to the list first, then open the chat, so the
                                // chat isn't pushed on top of this page.
                                showingRequests = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                    selectedConversationId = request.id
                                }
                            } label: {
                                ConversationRow(conversation: request, service: service,
                                                scamFlagged: requestLooksLikeScam(request.id))
                            }
                            .buttonStyle(.plain)
                            .task(id: request.id) { await service.checkRequestForScam(request.id) }
                            .swipeActions {
                                Button("Delete", role: .destructive) { service.deleteConversation(request.id) }
                            }
                        }
                    } footer: {
                        Text("People you haven't chatted with. They can't see that you've read their messages, or your name and photo, until you accept.")
                    }
                }
                .navigationTitle("Message Requests")
                .navigationBarTitleDisplayMode(.inline)
                .onChange(of: service.messageRequests.isEmpty) { _, empty in if empty { showingRequests = false } }
        }
        .navigationDestination(isPresented: $showingFolderManager) {
            ChatFoldersView(service: service)
        }
        .alert("New Folder", isPresented: Binding(
            get: { newFolderForConversation != nil },
            set: { if !$0 { newFolderForConversation = nil } }
        )) {
            TextField("Name", text: $newFolderName)
            Button("Create") {
                if let id = newFolderForConversation, let name = folderStore.add(newFolderName) {
                    service.setConversationLabel(id, label: name)
                }
            }
            .disabled(folderStore.validName(newFolderName) == nil)
            Button("Cancel", role: .cancel) {}
        }
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
            // Face ID-locked chats aren't searchable by content either.
            let lockedIds = Set(service.conversations.filter(\.requireBiometricChat).map(\.id))
            let messageResults = searchResults.filter {
                !panicMode.isHidden($0.conversationId) && !lockedIds.contains($0.conversationId)
            }
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

    /// The group id if `conversationId` is a group we're still in; otherwise nil.
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
                deleteError = FriendlyError.message(for: error)
            }
        }
    }

}

// MARK: - New Chat Sheet

private struct NewChatSheet: View {
    let service: MessagingService
    let onConversationStarted: (String) -> Void
    let onQRScanned: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var contacts: [ContactEntry] = []
    @State private var authDenied = false
    @State private var isLoadingContacts = false
    /// The user tapped "Find contacts on Relay" (and has consented).
    @State private var discoveryStarted = false
    @State private var showingDiscoveryConsent = false
    @State private var searchText = ""
    @State private var startingContactEmail: String?
    @State private var invitePayload: InvitePayload?
    @State private var addError: String?
    /// Set when the lookup failed (503 or offline). Contacts are then shown
    /// without Invite buttons rather than all as "not on Relay".
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
                    if !isSearching {
                        Section {
                            NavigationLink {
                                NewGroupView(embedded: true, service: service) { conversationId in
                                    dismiss()
                                    DispatchQueue.main.async { onConversationStarted(conversationId) }
                                }
                            } label: {
                                actionLabel("New Group", icon: "person.2.fill", color: .accentColor)
                            }
                            NavigationLink {
                                UsernameSearchSheet(embedded: true, service: service) { convId in
                                    dismiss()
                                    DispatchQueue.main.async { onConversationStarted(convId) }
                                } onDismiss: {}
                            } label: {
                                actionLabel("Find by Username", icon: "at", color: .blue)
                            }
                            NavigationLink {
                                ContactQRScanner(embedded: true) { username in
                                    dismiss()
                                    DispatchQueue.main.async { onQRScanned(username) }
                                }
                            } label: {
                                actionLabel("Scan QR Code", icon: "qrcode.viewfinder", color: .purple)
                            }
                            // Only after the user asks, and never on demo accounts
                            // (they can't reach real users).
                            if !service.isDemoAccount && !discoveryStarted {
                                Button {
                                    requestContactDiscovery()
                                } label: {
                                    actionLabel("Find Contacts on Relay", icon: "person.crop.circle.badge.checkmark", color: .green)
                                }
                                .tint(.primary)
                            }
                        } footer: {
                            if !service.isDemoAccount && !discoveryStarted {
                                Text("Find Contacts checks which of your contacts use Relay. Their addresses are blinded on your iPhone first.")
                            }
                        }

                        if !recentPeople.isEmpty {
                            Section("Recent") {
                                ForEach(recentPeople) { conversation in personRow(conversation) }
                            }
                        }
                    }

                    // Searching before (or without) contact discovery: the people
                    // you already chat with, so the list is never just blank.
                    if isSearching && (service.isDemoAccount || !discoveryStarted || authDenied) {
                        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
                        let matches = searchablePeople.filter {
                            service.displayName(forAccount: $0.peerAccount).lowercased().contains(q)
                                || ($0.peerUsername?.lowercased().contains(q) ?? false)
                        }
                        Section {
                            if matches.isEmpty {
                                Text("No chats match \"\(searchText)\". To start a new one, use Find by Username.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(matches) { conversation in personRow(conversation) }
                            }
                        }
                    }

                    if service.isDemoAccount || !discoveryStarted {
                        EmptyView()
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
                .listStyle(.insetGrouped)
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
            .navigationTitle("New Chat")
            .navigationBarTitleDisplayMode(.inline)
            // A scanned invite code opens its own screen; get out of the way.
            .onChange(of: model.pendingContactInviteToken) { _, token in if token != nil { dismiss() } }
            .onChange(of: model.pendingGroupInviteToken) { _, token in if token != nil { dismiss() } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
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

    /// Runs only from "Find contacts on Relay". Asks for consent the first
    /// time; the answer is remembered.
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

    private func actionLabel(_ title: String, icon: String, color: Color) -> some View {
        // The same grey tiles as Settings.
        HStack(spacing: 14) {
            SettingsIcon(systemName: icon, color: color)
            Text(title).foregroundStyle(.primary)
        }
    }

    /// People with a 1:1 chat, most recent first, to message again quickly.
    private var recentPeople: [Conversation] {
        Array(searchablePeople.prefix(8))
    }

    private var searchablePeople: [Conversation] {
        service.conversations
            .filter { !$0.isGroup && !$0.isRequest && !$0.archived
                && $0.peerAccount != service.noteToSelfAccount && $0.peerAccount != service.relayOfficialAccount
                && !PanicModeManager.shared.isHidden($0.id) }
            .sorted { ($0.lastMessageAt ?? 0) > ($1.lastMessageAt ?? 0) }
    }

    private func personRow(_ conversation: Conversation) -> some View {
        Button {
            dismiss()
            DispatchQueue.main.async { onConversationStarted(conversation.id) }
        } label: {
            HStack(spacing: 12) {
                AvatarView(name: service.displayName(forAccount: conversation.peerAccount), size: 36,
                           imageData: service.peerAvatarData(forAccount: conversation.peerAccount))
                VStack(alignment: .leading, spacing: 1) {
                    Text(service.displayName(forAccount: conversation.peerAccount))
                        .foregroundStyle(.primary)
                    if let username = conversation.peerUsername {
                        Text("@\(username)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .tint(.primary)
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
                addError = FriendlyError.message(for: error)
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

        // enumerateContacts is synchronous and slow; keep it off the main thread.
        let raw = await Task.detached(priority: .userInitiated) { Self.readAddressBook() }.value

        // If two contacts share an email, keep the first.
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

    private nonisolated static func readAddressBook() -> [(name: String, emails: [String], phones: [String], avatar: Data?)] {
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey,
                    CNContactEmailAddressesKey, CNContactPhoneNumbersKey,
                    CNContactThumbnailImageDataKey,
                    CNContactImageDataAvailableKey] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .givenName

        var raw: [(name: String, emails: [String], phones: [String], avatar: Data?)] = []
        try? CNContactStore().enumerateContacts(with: request) { contact, _ in
            let emails = contact.emailAddresses.map { ($0.value as String).lowercased().trimmingCharacters(in: .whitespaces) }
            let phones = contact.phoneNumbers.map { $0.value.stringValue }
            guard !emails.isEmpty || !phones.isEmpty else { return }
            let name = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
            let avatar = contact.imageDataAvailable ? contact.thumbnailImageData : nil
            raw.append((name: name.isEmpty ? (emails.first ?? phones.first ?? "") : name,
                        emails: emails, phones: phones, avatar: avatar))
        }
        return raw
    }

    /// Matches every contact email against the directory in one blinded batch.
    /// A failure is shown as an error with Retry, not as "not on Relay", which
    /// would offer Invite to people already here.
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
            discoveryError = FriendlyError.message(for: error)
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
    /// Pushed inside another navigation stack (no stack or Cancel of its own).
    var embedded = false
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
        OptionalNavigationStack(enabled: !embedded) {
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
            .navigationTitle("Find by Username")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { onDismiss() }
                    }
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
                lookupState = .error(FriendlyError.message(for: error))
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
                lookupState = .error("Couldn't start conversation: \(FriendlyError.message(for: error))")
            }
        }
    }
}

private struct ConversationRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let conversation: Conversation
    let service: MessagingService
    /// A message request whose messages look like a scam (ScamCheck.swift).
    var scamFlagged = false

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
        if conversation.hidePreviews || conversation.requireBiometricChat { return (nil, "Preview hidden") }
        let draft = service.readDraft(for: conversation.id)
        if !draft.isEmpty { return ("pencil", "Draft: \(draft)") }
        let isNoteToSelf = conversation.peerAccount == service.noteToSelfAccount
        let prefix = conversation.lastMessageIsOutgoing && !isNoteToSelf ? "You: " : ""
        switch conversation.lastMessageBody {
        case "~loc~":   return ("location.fill", "\(prefix)Location")
        case "~photo~": return ("photo.fill", "\(prefix)Photo")
        case "~sticker~": return ("face.dashed", "\(prefix)Sticker")
        case "~audio~": return ("waveform", "\(prefix)Voice note")
        case "~file~":  return ("paperclip", "\(prefix)Attachment")
        case let body where body?.hasPrefix("__poll__:") == true:
            let json = String((body ?? "").dropFirst("__poll__:".count))
            let question = PollPayload.decode(json)?.question ?? json
            return ("chart.bar.xaxis", "\(prefix)Poll: \(question)")
        case let body where body?.hasPrefix(notepadPrefix) == true:
            return ("note.text", "\(prefix)Updated the shared notepad")
        case let body where body?.hasPrefix(MessagingService.viewOncePrefix) == true:
            return ("1.circle", "\(prefix)View-once media")
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
                // Name row; the date moves under the name at accessibility sizes.
                let nameRowLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 0))
                nameRowLayout {
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
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 6) }
                    HStack(spacing: 5) {
                        if isMuted {
                            Image(systemName: "bell.slash.fill")
                                .font(.caption2)
                                .accessibilityLabel("Muted")
                                .foregroundStyle(.tertiary)
                        }
                        if conversation.lastMessageIsOutgoing && !conversation.isGroup {
                            deliveryStatusIcon
                        }
                        if let ts = conversation.lastMessageAt {
                            Text(Self.relativeLabel(ts))
                                .font(hasUnread ? .caption.weight(.semibold) : .caption)
                                .foregroundStyle(hasUnread ? .primary : .secondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .animation(.spring(duration: 0.35), value: lastMessageStatusSymbol)
                }

                // Preview row
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
                if scamFlagged {
                    Label("Possible scam", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.14), in: .capsule)
                        .padding(.top, 1)
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
