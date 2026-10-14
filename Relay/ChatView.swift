//
//  ChatView.swift
//  Relay
//
//  Conversation view: message list, bubbles, compose bar and the long-press
//  reaction/action menu. Liquid Glass is used on the compose bar only;
//  bubbles are flat fills.
//

import CoreLocation
import Foundation
import MapKit
import OSLog
import PhotosUI
import RelayKit
import SecureStorage
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ChatView: View {
    let service: MessagingService
    let conversationId: String
    var onClose: (() -> Void)? = nil
    /// Message to scroll to on open (e.g. a search hit) instead of the bottom.
    var initialMessageId: String? = nil

    @Environment(ChatAppearance.self) private var appearance
    @Environment(CallManager.self) private var callManager
    @State private var isOnScreen = false
    @State private var confirmingBulkDelete = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.openURL) private var openURL

    @State private var draft = ""
    @State private var replyingTo: StoredMessage?
    @State private var forwardTarget: ForwardPayload?
    @State private var infoTarget: StoredMessage?
    @State private var selectedMessageIds: Set<String> = []
    @State private var showingAttachmentPreview = false
    @State private var showingComposerEmoji = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var pendingAttachments: [MessagingService.PendingAttachment] = []
    @State private var confirmSensitiveSend = false
    @State private var sensitiveSendBlocked = false
    @State private var viewOnce = false
    @State private var showingPhotoPicker = false
    @State private var showingFileImporter = false
    @State private var showingCamera = false
    @State private var recorder = VoiceRecorder()
    @State private var recordDenied = false
    @State private var showingVerification = false
    @State private var showingContactCard = false
    @State private var showingGroupInfo = false
    @State private var showingChatSettings = false
    @State private var verification: MessagingService.PeerVerification?
    /// In a group: members whose safety number changed, which blocks sends.
    @State private var changedGroupMembers: [String] = []
    @State private var showingChangedGroupMembers = false
    // AI
    @State private var smartReplies: [String] = []
    @State private var showingSummary = false
    @State private var summaryText: String?
    @State private var isFetchingAI = false
    // Notepad
    @State private var showingNotepad = false
    @State private var showingPollComposer = false
    @State private var showingStickers = false
    // Schedule
    @State private var showingSchedulePicker = false
    @State private var scheduledDate = Date().addingTimeInterval(3600)
    // Location
    @State private var showingLocationPicker = false
    @State private var locationShareDuration: TimeInterval = 3600
    @State private var locationManager = LocationShareManager.shared
    @State private var chatAIEnabled: Bool = false
    @State private var chatNotepadEnabled: Bool = false

    private var isGroup: Bool { conversation?.isGroup == true }
    private var isNoteToSelf: Bool { conversation?.peerAccount == service.noteToSelfAccount }
    /// In a group, the member who is typing; in a 1:1 chat, the peer.
    private var typingName: String {
        guard isGroup, let account = service.typingSenders[conversationId] else { return peerName }
        return service.displayName(forAccount: account)
    }
    private var typingAvatar: Data? {
        guard isGroup, let account = service.typingSenders[conversationId] else { return peerAvatar }
        return service.peerAvatarData(forAccount: account)
    }
    private var isRelayOfficial: Bool { conversation?.peerAccount == service.relayOfficialAccount }
    /// The 1:1 peer if blocked. The composer is replaced with an unblock bar,
    /// since sends to a blocked peer are dropped.
    private var blockedPeer: String? {
        guard let conversation, !conversation.isGroup,
              service.isBlocked(conversation.peerAccount) else { return nil }
        return conversation.peerAccount
    }
    private var isRequest: Bool { conversation?.isRequest ?? false }
    @State private var confirmBlockRequest = false
    @State private var showingRequestReport = false
    private var callControlsDisabled: Bool {
        if case .idle = callManager.state { return false }
        return true
    }
    @State private var pinnedMessage: StoredMessage?
    @State private var showingStarred = false
    @State private var mentionQuery: String? = nil
    @AppStorage(PrivacyPreferences.incognitoKeyboardKey) private var incognitoKeyboard = true
    @State private var lastTypingSentAt: Date?
    @State private var isAtBottom = true
    @State private var scrollViewProxy: ScrollViewProxy?
    // In-chat search
    @State private var inChatSearchActive = false
    @State private var inChatQuery = ""
    @State private var inChatMatches: [StoredMessage] = []
    @State private var inChatMatchIndex = 0
    @State private var composerFocused = false
    @State private var composerContext = ComposerContext()
    @State private var showFormattingBar = false
    @State private var editingMessage: StoredMessage? = nil
    @State private var safariURL: URL?
    /// The message that was first before loading earlier ones, so the view
    /// stays where it was instead of jumping.
    @State private var earlierLoadAnchorId: String?
    @State private var initialScrollDone = false
    @State private var newMessageBanner: String? = nil

    private var conversation: Conversation? {
        service.conversations.first { $0.id == conversationId }
    }

    private var peerName: String {
        if isNoteToSelf { return "Note to Self" }
        if let account = conversation?.peerAccount { return service.displayName(forAccount: account) }
        return "Chat"
    }

    private var peerAvatar: Data? {
        guard !isGroup, let account = conversation?.peerAccount else { return nil }
        return service.peerAvatarData(forAccount: account)
    }

    private var isSelectingMessages: Bool { !selectedMessageIds.isEmpty }

    private var selectedMessages: [StoredMessage] {
        service.activeMessages.filter { selectedMessageIds.contains($0.id) }
    }

    private var connectionSubtitle: String? {
        switch service.connectionState {
        case .connected: return nil
        case .connecting: return "Connecting..."
        case .disconnected: return "Offline"
        }
    }

    private var rawScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if service.hasEarlierMessages && initialScrollDone {
                        Button("Load Earlier Messages") {
                            earlierLoadAnchorId = service.activeMessages.first?.id
                            service.loadEarlierMessages()
                        }
                        .font(.footnote.weight(.semibold))
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                    }
                    ForEach(displayItems) { item in
                        switch item {
                        case .dateSeparator(let id, let label):
                            Text(label)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(.ultraThinMaterial, in: .capsule)
                                .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .id(id)
                        case .unreadSeparator:
                            HStack(spacing: 8) {
                                Rectangle().fill(Color.accentColor.opacity(0.4)).frame(height: 1)
                                Text("New Messages")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .fixedSize()
                                Rectangle().fill(Color.accentColor.opacity(0.4)).frame(height: 1)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        case .message(let message, let position):
                            if message.senderAccount == MessagingService.systemSender {
                                SystemMessageView(rawBody: message.body)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 4)
                                    .id(message.id)
                            } else {
                                MessageRow(
                                    message: message,
                                    position: position,
                                    peerName: peerName,
                                    service: service,
                                    conversationId: conversationId,
                                    isGroup: isGroup,
                                    onReply: { beginReply(message) },
                                    onForward: { forwardTarget = ForwardPayload(messages: [message]) },
                                    onEdit: { editingMessage = message; draft = message.body; composerFocused = true },
                                    onInfo: { infoTarget = message },
                                    onUpdatePin: { pinnedMessage = service.pinnedMessage(for: conversationId) },
                                    isCurrentSearchMatch: isCurrentSearchMatch(message),
                                    isSelectionMode: isSelectingMessages,
                                    isSelected: selectedMessageIds.contains(message.id),
                                    onToggleSelection: { toggleMessageSelection(message) },
                                    onBeginSelection: { beginMessageSelection(message) }
                                )
                                .padding(.top, (position == .first || position == .single) ? 6 : 1)
                                .id(message.id)
                            }
                        }
                    }
                    if service.typingConversations.contains(conversationId) {
                        TypingIndicatorView(peerName: typingName, imageData: typingAvatar)
                            .id(Self.typingAnchor)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .opacity(initialScrollDone ? 1 : 0)
            .onChange(of: service.messagesLoadedConversationId) { _, loaded in
                guard loaded == conversationId, !initialScrollDone else { return }
                // Scroll first (applied on the next layout pass), then reveal the
                // view so the jump to the bottom isn't visible.
                DispatchQueue.main.async {
                    if let target = initialMessageId,
                       service.activeMessages.contains(where: { $0.id == target }) {
                        proxy.scrollTo(target, anchor: .center)
                    } else {
                        scrollToBottom(proxy, animated: false)
                    }
                    DispatchQueue.main.async { initialScrollDone = true }
                }
            }
            .onChange(of: service.activeMessages.first?.id) {
                guard let anchor = earlierLoadAnchorId else { return }
                earlierLoadAnchorId = nil
                DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
            }
            // Keyed on the newest message, not the count: the count stops
            // changing once a chat has a full page of messages.
            .onChange(of: service.activeMessages.last?.id) {
                guard initialScrollDone else { return }
                guard let last = service.activeMessages.last else { return }
                if last.isOutgoing || isAtBottom {
                    scrollToBottom(proxy)
                } else {
                    let sender = isGroup
                        ? service.displayName(forAccount: last.senderAccount ?? "")
                        : peerName
                    withAnimation(.spring(duration: 0.3)) { newMessageBanner = sender }
                    Task {
                        try? await Task.sleep(for: .seconds(3))
                        withAnimation(.spring(duration: 0.3)) { newMessageBanner = nil }
                    }
                }
                fetchSmartReplies(for: last)
                if !last.isOutgoing { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
            }
            .onChange(of: service.typingConversations.contains(conversationId)) { _, isTyping in
                if isTyping { scrollToBottom(proxy) }
            }
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height < 300
            } action: { _, atBottom in
                withAnimation(.spring(duration: 0.2)) { isAtBottom = atBottom }
                if atBottom { withAnimation(.spring(duration: 0.3)) { newMessageBanner = nil } }
            }
            .onAppear {
                scrollViewProxy = proxy
            }
            .overlay {
                if service.messagesLoadedConversationId == conversationId
                    && service.activeMessages.isEmpty
                    && !inChatSearchActive {
                    chatEmptyState
                }
            }
        }
    }

    @ViewBuilder
    private var chatEmptyState: some View {
        VStack(spacing: 16) {
            AvatarView(
                name: peerName,
                size: 80,
                imageData: isGroup ? service.group(for: conversationId)?.avatarData : peerAvatar
            )
            VStack(spacing: 5) {
                Text(peerName)
                    .font(.title3.weight(.semibold))
                Text(isNoteToSelf ? "Write a note to yourself" : "Say hi to \(peerName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !isNoteToSelf {
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill")
                        .font(.caption2.weight(.semibold))
                    Text("End-to-end encrypted")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private var linkOpener: OpenURLAction {
        OpenURLAction { url in
            guard url.scheme == "https" || url.scheme == "http" else { return .systemAction }
            safariURL = url
            return .handled
        }
    }

    var body: some View {
        rawScrollView
        // The screenshot-hidden container re-hosts its content in a separate
        // UIHostingController that doesn't inherit this environment. Re-inject
        // everything the rows read, or they trap on a missing @Environment object.
        .environment(appearance)
        .environment(callManager)
        .environment(\.openURL, linkOpener)
        .hiddenInScreenshots(service.effectiveScreenHidden(conversationId), fillsProposal: true)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            // Only the chat on screen reports a screenshot; ChatViews alive under
            // a sheet or in another tab stay quiet.
            guard isOnScreen, UIApplication.shared.applicationState == .active else { return }
            service.sendScreenshotAlert(conversationId: conversationId)
        }
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        .background { appearance.background.ignoresSafeArea(.all) }
        .environment(\.openURL, linkOpener)
        .sheet(item: $safariURL) { url in
            SafariView(url: url).ignoresSafeArea()
        }
        .navigationTitle(peerName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(horizontalSizeClass == .compact ? .hidden : .visible, for: .tabBar)
        .toolbarBackground(.clear, for: .navigationBar)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbar {
            if horizontalSizeClass == .regular, let onClose {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "chevron.left")
                            .accessibilityLabel("Back")
                    }
                }
            }
            ToolbarItem(placement: .principal) {
                Button {
                    if isRelayOfficial { }
                    else if isGroup { showingGroupInfo = true }
                    else { showingContactCard = true }
                } label: {
                    HStack(spacing: 8) {
                        if isRelayOfficial {
                            RelayOfficialAvatar(size: 34)
                        } else {
                            AvatarView(name: peerName, size: 34, imageData: isGroup ? service.group(for: conversationId)?.avatarData : peerAvatar)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                if let symbol = verification?.state.titleSymbol {
                                    Image(systemName: symbol.name)
                                        .foregroundStyle(symbol.tint)
                                        .font(.caption2)
                                }
                                Text(peerName)
                                    .font(.subheadline.weight(.semibold))
                                if isRelayOfficial {
                                    Image(systemName: "checkmark.seal.fill")
                                        .foregroundStyle(.blue)
                                        .font(.caption2)
                                }
                            }
                            if isRelayOfficial {
                                Text("Official account")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else if let connectionSubtitle {
                                Text(connectionSubtitle)
                                    .font(.caption2)
                                    .foregroundStyle(service.connectionState == .connecting ? .orange : .secondary)
                            } else if let secs = conversation?.disappearingSeconds, secs > 0 {
                                Label(disappearingLabel(secs), systemImage: "timer")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
                .tint(.primary)
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    if !isGroup && !isNoteToSelf && !isRelayOfficial {
                        Button {
                            if let account = conversation?.peerAccount {
                                Task { await callManager.startCall(peerAccount: account, peerName: peerName) }
                            }
                        } label: {
                            Image(systemName: "phone.fill")
                                .accessibilityLabel("Voice call")
                        }
                        .disabled(callControlsDisabled)

                        Button {
                            if let account = conversation?.peerAccount {
                                Task { await callManager.startCall(peerAccount: account, peerName: peerName, kind: .video) }
                            }
                        } label: {
                            Image(systemName: "video.fill")
                                .accessibilityLabel("Video call")
                        }
                        .disabled(callControlsDisabled)
                    }

                    if isGroup, let grp = service.group(for: conversationId) {
                        Button {
                            let others = grp.members.filter { $0 != (callManager.ownAccountId ?? "") }
                            Task {
                                await callManager.startGroupCall(
                                    groupId: grp.id,
                                    groupName: grp.name,
                                    participants: others,
                                    kind: .audio
                                )
                            }
                        } label: {
                            Image(systemName: "phone.badge.plus")
                                .accessibilityLabel("Start group call")
                        }
                        .disabled(callManager.isInGroupCall || callControlsDisabled)
                    }

                    Menu {
                        Button {
                            inChatSearchActive.toggle()
                            if !inChatSearchActive { inChatQuery = ""; inChatMatches = [] }
                        } label: {
                            Label(inChatSearchActive ? "Close Search" : "Search Chat", systemImage: "magnifyingglass")
                        }

                        if chatNotepadEnabled {
                            Button {
                                showingNotepad = true
                            } label: {
                                Label("Shared Notepad", systemImage: "note.text")
                            }
                        }

                        if #available(iOS 26.0, *), chatAIEnabled, !isGroup, AIAssistant.shared.isAvailable {
                            Button {
                                Task { await fetchSummary() }
                            } label: {
                                Label("AI Summary", systemImage: isFetchingAI ? "hourglass" : "sparkles")
                            }
                            .disabled(isFetchingAI)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("Chat actions")
                }
            }
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                if inChatSearchActive {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search in conversation…", text: $inChatQuery)
                            .autocorrectionDisabled()
                            .onSubmit { runInChatSearch() }
                        if !inChatMatches.isEmpty {
                            Text("\(inChatMatchIndex + 1)/\(inChatMatches.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Button { stepInChatMatch(by: -1) } label: {
                                Image(systemName: "chevron.up")
                                    .accessibilityLabel("Previous match")
                            }
                            .buttonStyle(.plain)
                            Button { stepInChatMatch(by: 1) } label: {
                                Image(systemName: "chevron.down")
                                    .accessibilityLabel("Next match")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .glassCompat(in: .rect(cornerRadius: 18))
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                    .onChange(of: inChatQuery) { _, _ in runInChatSearch() }
                }
                if let pinnedMessage {
                    PinnedMessageBanner(message: pinnedMessage) {
                        service.pinMessage(pinnedMessage.id, pinned: false, in: conversationId)
                        self.pinnedMessage = nil
                    }
                }
                if isGroup, !changedGroupMembers.isEmpty {
                    groupSafetyNumberChangedBanner
                } else if verification?.state == .changed {
                    safetyNumberChangedBanner
                }
            }
        }
        .environment(\.relayIsMessageRequest, isRequest)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if !isAtBottom {
                    HStack {
                        Spacer()
                        Button {
                            if let p = scrollViewProxy { scrollToBottom(p) }
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "chevron.down")
                                    .accessibilityLabel("Scroll to latest")
                                    .font(.callout.weight(.bold))
                                    .frame(width: 34, height: 34)
                                    .glassCompat(in: .circle)
                                if let count = conversation?.unreadCount, count > 0 {
                                    CountBadge(count: count)
                                        .offset(x: 6, y: -6)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 16)
                    }
                    .padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if !mentionSuggestions.isEmpty {
                    mentionPicker
                }
                if !smartReplies.isEmpty && !isRequest {
                    smartReplyStrip
                }
                if let sender = newMessageBanner {
                    Button {
                        withAnimation(.spring(duration: 0.3)) { newMessageBanner = nil }
                        if let p = scrollViewProxy { scrollToBottom(p) }
                    } label: {
                        Label("New message from \(sender)", systemImage: "arrow.down.circle.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.accentColor, in: .capsule)
                            .shadow(color: .accentColor.opacity(0.3), radius: 8, y: 4)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if isRelayOfficial {
                    Label("You can't reply to Relay", systemImage: "checkmark.seal.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial)
                } else if isRequest, blockedPeer == nil {
                    messageRequestBar
                } else if let blockedPeer {
                    HStack(spacing: 12) {
                        Label("You blocked \(peerName)", systemImage: "hand.raised.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Unblock") { service.unblockAccount(blockedPeer) }
                            .font(.footnote.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                } else if isAnnounceOnlyBlocked {
                    Label("Only admins can send messages", systemImage: "megaphone.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial)
                } else if isSelectingMessages {
                    selectionActionBar
                } else {
                    composeBar
                }
            }
            .animation(.spring(duration: 0.2), value: isAtBottom)
            .animation(.spring(duration: 0.3), value: newMessageBanner != nil)
        }
        .alert(
            "Message Not Sent",
            isPresented: Binding(
                get: { service.sendErrorMessage != nil },
                set: { if !$0 { service.sendErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(service.sendErrorMessage ?? "")
        }
        .sheet(isPresented: $showingVerification, onDismiss: refreshVerification) {
            NavigationStack { VerificationView(service: service, conversationId: conversationId, peerName: peerName) }
        }
        .sheet(isPresented: $showingChangedGroupMembers, onDismiss: refreshVerification) {
            NavigationStack { GroupSafetyNumbersView(service: service, conversationId: conversationId) }
        }
        .sheet(isPresented: $showingGroupInfo) {
            GroupInfoView(
                service: service,
                conversationId: conversationId,
                ownAccountId: service.credentials.accountId
            )
        }
        .sheet(isPresented: $showingContactCard, onDismiss: {
            refreshVerification()
            chatAIEnabled = UserDefaults.standard.bool(forKey: "chat.ai.\(conversationId)")
            chatNotepadEnabled = UserDefaults.standard.bool(forKey: "chat.notepad.\(conversationId)")
        }) {
            ContactCardView(service: service, conversationId: conversationId, onActivateSearch: {
                showingContactCard = false
                inChatSearchActive = true
            })
        }
        .sheet(isPresented: $showingChatSettings, onDismiss: {
            chatNotepadEnabled = UserDefaults.standard.bool(forKey: "chat.notepad.\(conversationId)")
        }) {
            if let conversation {
                NavigationStack { ChatPrivacySettingsView(service: service, conversation: conversation) }
            }
        }
        .sheet(item: $forwardTarget) { payload in
            ForwardMessageSheet(payload: payload, service: service)
        }
        .sheet(item: $infoTarget) { message in
            NavigationStack {
                MessageInfoView(
                    message: message, isOwnAuthor: isOwn(message), peerName: peerName,
                    service: service, conversationId: conversationId, isGroup: isGroup
                )
            }
        }
        .sheet(isPresented: $showingComposerEmoji) {
            EmojiPicker { draft += $0 }
        }
        .sheet(isPresented: $showingAttachmentPreview) {
            PendingAttachmentPreviewSheet(
                attachments: pendingAttachments,
                caption: $draft,
                viewOnce: $viewOnce,
                onRemove: removePendingAttachment,
                onSend: send
            )
        }
        .sheet(isPresented: $showingNotepad) {
            NotepadView(service: service, conversationId: conversationId, peerName: peerName)
        }
        .sheet(isPresented: $showingSummary) {
            SummarySheet(text: summaryText ?? "")
        }
        .sheet(isPresented: $showingStarred) {
            NavigationStack { StarredMessagesView(service: service, conversationId: conversationId, peerName: peerName) }
        }
        .sheet(isPresented: $showingSchedulePicker) {
            SchedulePickerSheet(
                draft: draft,
                scheduledDate: $scheduledDate
            ) { date in
                let body = draft
                service.scheduleMessage(body, in: conversationId, at: date)
                draft = ""
                clearPendingAttachments()
            }
        }
        .sheet(isPresented: $showingStickers) {
            StickerPickerSheet { png in
                let size = UIImage(data: png)?.size ?? CGSize(width: 384, height: 384)
                let sticker = MessagingService.PendingAttachment(
                    data: png, contentType: "image/png", filename: nil,
                    width: Int(size.width), height: Int(size.height)
                )
                Task {
                    await service.sendMessage(MessagingService.stickerMarker, in: conversationId,
                                              replyTo: nil, attachments: [sticker])
                }
            }
        }
        .sheet(isPresented: $showingPollComposer) {
            PollComposerSheet { question, options, multiSelect in
                Task { await service.sendPoll(question: question, options: options, multiSelect: multiSelect, in: conversationId) }
            }
        }
        .sheet(isPresented: $showingLocationPicker) {
            LocationShareSheet(duration: $locationShareDuration) { duration in
                locationManager.start(in: conversationId, duration: duration, service: service)
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    if let loc = locationManager.latestLocation {
                        let payload = LocationPayload(
                            lat: loc.coordinate.latitude,
                            lng: loc.coordinate.longitude,
                            exp: Int64((Date().timeIntervalSince1970 + duration) * 1000),
                            stop: false
                        )
                        await service.sendLiveLocation(payload.encode(), in: conversationId)
                    }
                }
            }
        }
        .onAppear {
            refreshVerification()
            pinnedMessage = service.pinnedMessage(for: conversationId)
            draft = service.readDraft(for: conversationId)
            chatAIEnabled = UserDefaults.standard.bool(forKey: "chat.ai.\(conversationId)")
            chatNotepadEnabled = UserDefaults.standard.bool(forKey: "chat.notepad.\(conversationId)")
        }
        .onChange(of: service.activeMessagesRevision) {
            refreshVerification()
            pinnedMessage = service.pinnedMessage(for: conversationId)
        }
        .onChange(of: service.blockedSafetyWarningConversationId) { _, blockedConversationId in
            guard blockedConversationId == conversationId else { return }
            refreshVerification()
            if isGroup {
                showingChangedGroupMembers = true
            } else {
                showingVerification = true
            }
            service.clearBlockedSafetyWarning()
        }
        .onChange(of: draft) { _, newValue in
            let normalized = normalizedDraft(newValue)
            if normalized != newValue {
                draft = normalized
                return
            }
            updateTypingState(for: normalized)
            if isGroup {
                let words = normalized.components(separatedBy: .whitespacesAndNewlines)
                if let lastWord = words.last, lastWord.hasPrefix("@") {
                    mentionQuery = String(lastWord.dropFirst())
                } else {
                    mentionQuery = nil
                }
            }
        }
        .onDisappear {
            if lastTypingSentAt != nil { service.sendTyping(.stopped, in: conversationId) }
            if editingMessage == nil { service.saveDraft(draft, for: conversationId) }
            editingMessage = nil
        }
    }

    // MARK: - AI helpers

    private func fetchSummary() async {
        guard #available(iOS 26.0, *) else { return }
        guard !isFetchingAI else { return }
        isFetchingAI = true
        defer { isFetchingAI = false }
        do {
            summaryText = try await AIAssistant.shared.summarize(service.activeMessages)
            showingSummary = true
        } catch {
            summaryText = FriendlyError.message(for: error)
            showingSummary = true
        }
    }

    private func fetchSmartReplies(for message: StoredMessage) {
        guard chatAIEnabled else { return }
        guard #available(iOS 26.0, *), AIAssistant.shared.isAvailable, !message.isOutgoing else { return }
        Task {
            let replies = (try? await AIAssistant.shared.suggestReplies(to: message, peerName: peerName)) ?? []
            withAnimation(.spring(duration: 0.25)) { smartReplies = replies }
        }
    }

    // MARK: - Smart reply strip

    private var smartReplyStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(smartReplies, id: \.self) { reply in
                    Button {
                        draft = reply
                        withAnimation { smartReplies = [] }
                        composerFocused = true
                    } label: {
                        Text(reply)
                            .font(.subheadline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .glassCompat(in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    withAnimation { smartReplies = [] }
                } label: {
                    Image(systemName: "xmark")
                        .accessibilityLabel("Dismiss suggestions")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss suggestions")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private static let typingAnchor = "typing-indicator"
    private static let maxDraftLines = 4
    private static let composerControlHeight: CGFloat = 44
    private static let composerAccessoryWidth: CGFloat = 48

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let action = {
            if service.typingConversations.contains(conversationId) {
                proxy.scrollTo(Self.typingAnchor, anchor: .bottom)
            } else if let last = service.activeMessages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
        if animated { withAnimation(.snappy) { action() } } else { action() }
    }

    private var safetyNumberChangedBanner: some View {
        Button {
            showingVerification = true
        } label: {
            Label("\(peerName)’s safety number changed — tap to verify", systemImage: "exclamationmark.shield.fill")
                .font(.footnote.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.orange.opacity(0.9), in: .rect)
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private var groupSafetyNumberChangedBanner: some View {
        Button {
            showingChangedGroupMembers = true
        } label: {
            Label(groupSafetyNumberChangedText, systemImage: "exclamationmark.shield.fill")
                .font(.footnote.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.orange.opacity(0.9), in: .rect)
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private var groupSafetyNumberChangedText: String {
        if changedGroupMembers.count == 1, let member = changedGroupMembers.first {
            return "\(service.displayName(forAccount: member))’s safety number changed — tap to verify"
        }
        return "\(changedGroupMembers.count) members’ safety numbers changed — tap to review"
    }

    private func refreshVerification() {
        if isGroup {
            changedGroupMembers = service.groupMembersWithChangedSafetyNumbers(conversationId)
        } else {
            verification = service.peerVerification(for: conversationId)
        }
    }

    private var mentionSuggestions: [String] {
        guard isGroup, let q = mentionQuery else { return [] }
        let members = service.group(for: conversationId)?.members ?? []
        return members.filter { account in
            account != service.credentials.accountId &&
            (q.isEmpty || service.displayName(forAccount: account).localizedCaseInsensitiveContains(q))
        }
    }

    private var mentionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(mentionSuggestions, id: \.self) { account in
                    Button {
                        insertMention(account)
                    } label: {
                        HStack(spacing: 6) {
                            AvatarView(name: service.displayName(forAccount: account), size: 24,
                                       imageData: service.peerAvatarData(forAccount: account))
                            Text(service.displayName(forAccount: account))
                                .font(.subheadline.weight(.medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .glassCompat(in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }

    private func insertMention(_ account: String) {
        let name = service.displayName(forAccount: account)
        var words = draft.components(separatedBy: .whitespacesAndNewlines)
        if words.last?.hasPrefix("@") == true {
            words[words.count - 1] = "@\(name)"
        } else {
            words.append("@\(name)")
        }
        draft = words.joined(separator: " ") + " "
        mentionQuery = nil
    }

    private func disappearingLabel(_ seconds: Int64) -> String {
        switch seconds {
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86400)d"
        }
    }

    /// Whether the local user wrote the message (for quote/reply attribution).
    private func isOwn(_ message: StoredMessage) -> Bool {
        message.isOutgoing
    }

    private func quoteAuthor(of message: StoredMessage) -> String {
        message.isOutgoing ? service.credentials.accountId : (conversation?.peerAccount ?? "")
    }

    private func runInChatSearch() {
        let q = inChatQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { inChatMatches = []; return }
        inChatMatches = service.activeMessages.filter {
            $0.body.localizedCaseInsensitiveContains(q)
        }
        inChatMatchIndex = inChatMatches.isEmpty ? 0 : inChatMatches.count - 1
        scrollToMatch()
    }

    private func stepInChatMatch(by delta: Int) {
        guard !inChatMatches.isEmpty else { return }
        inChatMatchIndex = (inChatMatchIndex + delta + inChatMatches.count) % inChatMatches.count
        scrollToMatch()
    }

    private func scrollToMatch() {
        guard inChatMatchIndex < inChatMatches.count else { return }
        let id = inChatMatches[inChatMatchIndex].id
        withAnimation { scrollViewProxy?.scrollTo(id, anchor: .center) }
    }

    private func isCurrentSearchMatch(_ message: StoredMessage) -> Bool {
        guard inChatSearchActive, inChatMatches.indices.contains(inChatMatchIndex) else { return false }
        return inChatMatches[inChatMatchIndex].id == message.id
    }

    private func beginReply(_ message: StoredMessage) {
        replyingTo = message
        composerFocused = true
    }

    // MARK: - Selection actions

    private var selectionActionBar: some View {
        GlassContainer {
            HStack(spacing: 10) {
                Button { clearMessageSelection() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 38, height: 38)
                        .glassCompat(in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Done selecting")

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(selectedMessageIds.count) selected")
                        .font(.subheadline.weight(.semibold))
                        .contentTransition(.numericText())
                    Text("Choose an action")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)

                Spacer(minLength: 0)
                selectionActionButton("doc.on.doc", label: "Copy") { copySelectedMessages() }
                    .disabled(!selectedMessages.contains { !$0.body.isEmpty })
                selectionActionButton("arrowshape.turn.up.right", label: "Forward") { forwardSelectedMessages() }
                    .disabled(!selectedMessages.contains {
                        (!$0.body.isEmpty || !$0.attachments.isEmpty) && !$0.body.hasPrefix(MessagingService.viewOncePrefix)
                    })
                selectionActionButton("star", label: "Star") { starSelectedMessages() }
                selectionActionButton("trash", label: "Delete", role: .destructive) { confirmingBulkDelete = true }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassCompat(in: .rect(cornerRadius: 24))
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .confirmationDialog(
            "Delete \(selectedMessageIds.count) message\(selectedMessageIds.count == 1 ? "" : "s") from this device?",
            isPresented: $confirmingBulkDelete,
            titleVisibility: .visible
        ) {
            Button("Delete for Me", role: .destructive) { deleteSelectedMessages() }
        }
    }

    private func selectionActionButton(
        _ systemName: String,
        label: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemName)
                    .font(.system(size: 17, weight: .semibold))
                Text(label)
                    .font(.caption2)
            }
            .frame(width: 52)
        }
        .buttonStyle(.plain)
    }

    private func beginMessageSelection(_ message: StoredMessage) {
        guard message.senderAccount != MessagingService.systemSender else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        selectedMessageIds = [message.id]
        composerFocused = false
    }

    private func toggleMessageSelection(_ message: StoredMessage) {
        if selectedMessageIds.contains(message.id) {
            selectedMessageIds.remove(message.id)
        } else {
            selectedMessageIds.insert(message.id)
        }
    }

    private func clearMessageSelection() {
        selectedMessageIds.removeAll()
    }

    private func copySelectedMessages() {
        let text = selectedMessages
            .map(\.body)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !text.isEmpty else { return }
        SecurePasteboard.copy(text)
        clearMessageSelection()
    }

    private func forwardSelectedMessages() {
        let messages = selectedMessages.filter {
            (!$0.body.isEmpty || !$0.attachments.isEmpty) && !$0.body.hasPrefix(MessagingService.viewOncePrefix)
        }
        guard !messages.isEmpty else { return }
        forwardTarget = ForwardPayload(messages: messages)
        clearMessageSelection()
    }

    private func starSelectedMessages() {
        for message in selectedMessages {
            service.starMessage(message.id, starred: true, in: conversationId)
        }
        clearMessageSelection()
    }

    private func deleteSelectedMessages() {
        for message in selectedMessages {
            service.deleteMessage(message.id, in: conversationId)
        }
        clearMessageSelection()
    }

    // MARK: - Compose bar

    private var formattingBar: some View {
        HStack(spacing: 2) {
            FormatButton(symbol: "bold", tip: "Bold") {
                composerContext.applyFormat(prefix: "**", suffix: "**")
            }
            FormatButton(symbol: "italic", tip: "Italic") {
                composerContext.applyFormat(prefix: "_", suffix: "_")
            }
            FormatButton(symbol: "strikethrough", tip: "Strikethrough") {
                composerContext.applyFormat(prefix: "~~", suffix: "~~")
            }
            FormatButton(symbol: "chevron.left.forwardslash.chevron.right", tip: "Code") {
                composerContext.applyFormat(prefix: "`", suffix: "`")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var composeBar: some View {
        VStack(spacing: 8) {
            if let editingMessage {
                EditPreviewBar(message: editingMessage) {
                    self.editingMessage = nil
                    draft = ""
                }
                .padding(.horizontal)
            }
            if let replyingTo {
                ReplyPreviewBar(
                    message: replyingTo,
                    isOwnAuthor: isOwn(replyingTo),
                    peerName: peerName,
                    onCancel: { self.replyingTo = nil }
                )
                .padding(.horizontal)
            }
            if !pendingAttachments.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(pendingAttachments.enumerated()), id: \.offset) { index, attachment in
                                PendingAttachmentBar(
                                    attachment: attachment,
                                    onPreview: { showingAttachmentPreview = true },
                                    onCancel: { removePendingAttachment(at: index) }
                                )
                                .frame(width: pendingAttachments.count == 1 ? nil : 156)
                            }
                        }
                        .padding(.horizontal)
                    }
                    if pendingAttachments.allSatisfy({ $0.contentType.hasPrefix("image/") }) {
                        Button {
                            viewOnce.toggle()
                        } label: {
                            Label("View once", systemImage: viewOnce ? "eye.fill" : "eye.slash")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(viewOnce ? Color.accentColor.opacity(0.15) : Color(.secondarySystemFill), in: .capsule)
                                .foregroundStyle(viewOnce ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal)
                    }
                }
            }
            if showFormattingBar {
                formattingBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            GlassContainer {
                if recorder.isRecording {
                    recordingBar
                        .padding(.horizontal)
                        .padding(.bottom, 6)
                } else {
                    HStack(alignment: .bottom, spacing: 6) {
                        Menu {
                            if !isNoteToSelf {
                                Button("Photo / Video", systemImage: "photo") { showingPhotoPicker = true }
                                if cameraAvailable {
                                    Button("Camera", systemImage: "camera") { showingCamera = true }
                                }
                                Button("File", systemImage: "doc") { showingFileImporter = true }
                                Button("Location", systemImage: "location.fill") { showingLocationPicker = true }
                                Button("Poll", systemImage: "chart.bar.xaxis") { showingPollComposer = true }
                                Button("Sticker", systemImage: "face.dashed") { showingStickers = true }
                            }
                            Button("Emoji", systemImage: "face.smiling") { showingComposerEmoji = true }
                            Button(showFormattingBar ? "Hide Formatting" : "Format", systemImage: "textformat") {
                                withAnimation(.spring(duration: 0.2)) { showFormattingBar.toggle() }
                            }
                        } label: {
                            composerAccessoryIcon("plus")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("More message options")

                        if showRecordButton {
                            Button { startRecording() } label: {
                                composerAccessoryIcon("mic.fill")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Record voice message")
                            .transition(.opacity)
                        }

                        FormattingTextEditor(
                            text: $draft,
                            placeholder: isNoteToSelf ? "Write a note…" : "Message \(peerName)…",
                            maxLines: Self.maxDraftLines,
                            context: composerContext,
                            isFocused: $composerFocused,
                            incognito: incognitoKeyboard
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: Self.composerControlHeight)
                        .glassCompat(in: .rect(cornerRadius: draftContainsLineBreak ? 16 : 22))

                        if showSendButton {
                            Button { send() } label: {
                                composerSendIcon
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(editingMessage == nil ? "Send message" : "Save edit")
                            // Hardware keyboards: Cmd-Return sends; Return inserts a newline.
                            .keyboardShortcut(.return, modifiers: .command)
                            .simultaneousGesture(
                                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                                    // Scheduled messages are text-only; attachments would be lost.
                                    guard canSend, editingMessage == nil, pendingAttachments.isEmpty,
                                          !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    else { return }
                                    scheduledDate = Date().addingTimeInterval(3600)
                                    showingSchedulePicker = true
                                }
                            )
                            .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.12), value: showRecordButton)
                    .animation(.easeOut(duration: 0.12), value: showSendButton)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                }
            }
        }
        .onChange(of: photoItems) { _, items in loadPickedPhotos(items) }
        .photosPicker(isPresented: $showingPhotoPicker, selection: $photoItems, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { loadPickedFile(url) }
        }
        .alert("Send something sensitive?", isPresented: $confirmSensitiveSend) {
            Button("Send Anyway") { sendNow() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This may contain nudity. Only send it if you're sure the person wants it, and remember it could be saved or shared.")
        }
        .alert("Can't send this", isPresented: $sensitiveSendBlocked) {
            Button("OK", role: .cancel) {}
            Button("Ways to Get Help") { openURL(SensitiveContent.helpURL) }
        } message: {
            Text("This photo or video may show private body parts. Talk to a parent or another adult you trust if someone asked you to send it.")
        }
        .alert("Microphone Access Needed", isPresented: $recordDenied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Enable microphone access in Settings to record voice messages.")
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { image in sendCameraPhoto(image) }
                .ignoresSafeArea()
        }
    }

    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    /// Sends a captured photo immediately, without a pending stage.
    private func sendCameraPhoto(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        let photo = MessagingService.PendingAttachment(
            data: data,
            contentType: "image/jpeg",
            filename: nil,
            width: Int(image.size.width * image.scale),
            height: Int(image.size.height * image.scale)
        )
        Task { await service.sendMessage("", in: conversationId, replyTo: nil, attachments: [photo]) }
    }

    /// Replaces the compose row while a voice message is being recorded.
    private var recordingBar: some View {
        HStack(spacing: 14) {
            Button {
                recorder.cancel()
            } label: {
                Image(systemName: "trash").font(.system(size: 20)).foregroundStyle(.red)
                    .accessibilityLabel("Delete recording")
            }
            .buttonStyle(.plain)

            Circle().fill(.red).frame(width: 9, height: 9)
            Text(formatDuration(recorder.elapsed))
                .font(.body.monospacedDigit())
            Spacer()
            Button {
                finishRecording()
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                    .accessibilityLabel("Send voice message")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassCompat()
    }

    private func composerAccessoryIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(Color(.label))
            .frame(width: Self.composerAccessoryWidth, height: Self.composerControlHeight)
            .contentShape(.capsule)
            .glassCompat(in: .capsule)
    }

    private var composerSendIcon: some View {
        Image(systemName: composerActionSymbol)
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: Self.composerAccessoryWidth, height: Self.composerControlHeight)
            .contentShape(.capsule)
            .background(Color.accentColor, in: .capsule)
            .glassCompat(in: .capsule)
    }

    /// Replaces the composer for a chat someone else started.
    private var messageRequestBar: some View {
        let isGroup = conversation?.isGroup ?? false
        return VStack(spacing: 12) {
            Text(isGroup
                 ? "You were added to this group by someone you haven't chatted with. They won't see your name or photo, or know you've read anything, until you accept."
                 : "\(peerName) wants to message you. They won't see your name or photo, or know you've read their messages, until you accept.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                if !isGroup || requestBlockTarget != nil {
                    Button(role: .destructive) { confirmBlockRequest = true } label: {
                        Text("Block").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Button(role: .destructive) {
                    removeRequest()
                } label: {
                    Text("Delete").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button { service.acceptMessageRequest(conversationId) } label: {
                    Text("Accept").bold().frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .confirmationDialog("Block \(requestBlockTarget.map { service.displayName(forAccount: $0) } ?? peerName)?",
                            isPresented: $confirmBlockRequest, titleVisibility: .visible) {
            Button("Block", role: .destructive) { blockRequest(report: false) }
            Button("Block and Report", role: .destructive) { blockRequest(report: true) }
        } message: {
            Text("They won't be able to message or call you, and this chat is deleted.")
        }
        .sheet(isPresented: $showingRequestReport, onDismiss: {
            removeRequest()
        }) {
            if let target = requestBlockTarget {
                ReportContactSheet(service: service, account: target,
                                   displayName: service.displayName(forAccount: target))
            }
        }
    }

    /// The person a request's Block and Report act on: the sender of a 1:1
    /// request, or whoever added us to a group (not the group itself).
    private var requestBlockTarget: String? {
        guard let conversation else { return nil }
        if let groupId = conversation.groupId { return service.groupRequestAdder(groupId: groupId) }
        return conversation.peerAccount
    }

    private func blockRequest(report: Bool) {
        guard let peer = requestBlockTarget else {
            removeRequest()
            return
        }
        service.blockAccount(peer)
        if report {
            showingRequestReport = true
        } else {
            removeRequest()
        }
    }

    /// Deletes a request. For a group that means leaving it too: deleting only
    /// the chat leaves us on the roster, and the next update brings it back.
    private func removeRequest() {
        if let conversation, let groupId = conversation.groupId {
            let id = conversation.id
            Task { try? await service.leaveGroup(groupId); service.deleteConversation(id) }
        } else {
            service.deleteConversation(conversationId)
        }
        onClose?()
    }

    private var isAnnounceOnlyBlocked: Bool {
        service.isAnnounceOnly(conversationId: conversationId) && !service.isAdmin(in: conversationId)
    }

    private var canSend: Bool {
        !isAnnounceOnlyBlocked
        && (!pendingAttachments.isEmpty || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var showRecordButton: Bool {
        !canSend && editingMessage == nil
    }

    private var showSendButton: Bool {
        canSend || editingMessage != nil
    }

    private var composerActionSymbol: String {
        editingMessage != nil ? "checkmark" : "arrow.up"
    }

    private var draftContainsLineBreak: Bool {
        draft.contains("\n") || draft.contains("\r")
    }

    private func normalizedDraft(_ text: String) -> String {
        let normalizedNewlines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalizedNewlines.components(separatedBy: "\n")
        guard lines.count > Self.maxDraftLines else { return normalizedNewlines }
        return lines.prefix(Self.maxDraftLines).joined(separator: "\n")
    }

    private func loadPickedPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            var loaded: [MessagingService.PendingAttachment] = []
            for item in items.prefix(10) {
                if let attachment = await pendingAttachment(from: item) {
                    loaded.append(attachment)
                }
            }
            guard !loaded.isEmpty else { return }
            pendingAttachments = loaded
            if !pendingAttachments.allSatisfy({ $0.contentType.hasPrefix("image/") }) {
                viewOnce = false
            }
        }
    }

    private func pendingAttachment(from item: PhotosPickerItem) async -> MessagingService.PendingAttachment? {
        let isVideo = item.supportedContentTypes.contains {
            $0.conforms(to: .movie) || $0.conforms(to: .video) || $0.conforms(to: .audiovisualContent)
        }
        let isGIF = item.supportedContentTypes.contains { $0.conforms(to: .gif) }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        if isVideo {
            let mime = item.supportedContentTypes.first {
                $0.conforms(to: .movie) || $0.conforms(to: .video)
            }?.preferredMIMEType ?? "video/mp4"
            // Without its location metadata; not sent if that can't be done.
            guard let clean = await MediaSanitizer.video(data, contentType: mime) else {
                service.postRelayNotice("A video couldn't be prepared for sending, so it was left out.")
                return nil
            }
            return MessagingService.PendingAttachment(
                data: clean, contentType: mime, filename: mime == "video/quicktime" ? "video.mov" : "video.mp4",
                width: 0, height: 0
            )
        }
        // Re-encode instead of forwarding the original bytes: strips EXIF/GPS
        // metadata and turns HEIC into the JPEG the content type promises.
        // GIFs keep their bytes so they still animate.
        guard let clean = MediaSanitizer.photo(data) else { return nil }
        return MessagingService.PendingAttachment(
            data: clean.data,
            contentType: clean.contentType,
            filename: isGIF ? "image.gif" : nil,
            width: clean.width,
            height: clean.height
        )
    }

    /// Reads a document-picker selection (a security-scoped URL) into a
    /// pending attachment.
    private func loadPickedFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        pendingAttachments = [MessagingService.PendingAttachment(
            data: data,
            contentType: mime,
            filename: url.lastPathComponent,
            width: 0,
            height: 0
        )]
        viewOnce = false
    }

    private func startRecording() {
        Task {
            if await recorder.start() == false { recordDenied = true }
        }
    }

    /// Stops recording and sends the clip immediately; voice notes have no
    /// pending stage.
    private func finishRecording() {
        guard let clip = recorder.finish() else { return }
        Task { await service.sendMessage("", in: conversationId, replyTo: nil, attachments: [clip]) }
    }

    private func clearPendingAttachments() {
        pendingAttachments = []
        photoItems = []
    }

    private func removePendingAttachment(at index: Int) {
        guard pendingAttachments.indices.contains(index) else { return }
        pendingAttachments.remove(at: index)
        if pendingAttachments.isEmpty {
            photoItems = []
            viewOnce = false
        } else if !pendingAttachments.allSatisfy({ $0.contentType.hasPrefix("image/") }) {
            viewOnce = false
        }
    }

    /// Checks outgoing photos and videos first when Sensitive Content Warning
    /// or Communication Safety is on.
    private func send() {
        guard canSend else { return }
        let media = pendingAttachments.filter { $0.contentType.hasPrefix("image/") || $0.contentType.hasPrefix("video/") }
        guard editingMessage == nil, !media.isEmpty, SensitiveContent.isEnabled else {
            sendNow()
            return
        }
        Task {
            for attachment in media where await Self.isSensitive(attachment) {
                if SensitiveContent.isRestricted {
                    sensitiveSendBlocked = true
                } else {
                    confirmSensitiveSend = true
                }
                return
            }
            sendNow()
        }
    }

    private static func isSensitive(_ attachment: MessagingService.PendingAttachment) async -> Bool {
        if attachment.contentType.hasPrefix("image/") {
            return await SensitiveContent.isSensitive(imageData: attachment.data)
        }
        guard let url = try? TempMediaFiles.write(attachment.data, originalName: attachment.filename, fallbackExtension: "mp4")
        else { return false }
        defer { TempMediaFiles.remove(url) }
        return await SensitiveContent.isSensitive(videoAt: url)
    }

    private func sendNow() {
        var text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if let target = editingMessage {
            guard !text.isEmpty else { return }
            draft = ""
            editingMessage = nil
            service.editMessage(target, newBody: text)
            return
        }
        let reply = replyingTo.map {
            QuotedMessage(
                targetTimestamp: $0.timestamp,
                author: quoteAuthor(of: $0),
                text: String($0.body.prefix(240))
            )
        }
        let attachments = pendingAttachments
        if viewOnce && !attachments.isEmpty { text = "~once~" + text }
        draft = ""
        replyingTo = nil
        viewOnce = false
        clearPendingAttachments()
        Task { await service.sendMessage(text, in: conversationId, replyTo: reply, attachments: attachments) }
    }

    /// Throttled typing broadcast: `.started` at most every few seconds while
    /// the field is non-empty, `.stopped` as soon as it empties.
    private func updateTypingState(for text: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if lastTypingSentAt != nil {
                service.sendTyping(.stopped, in: conversationId)
                lastTypingSentAt = nil
            }
        } else {
            let now = Date()
            if lastTypingSentAt.map({ now.timeIntervalSince($0) > 4 }) ?? true {
                service.sendTyping(.started, in: conversationId)
                lastTypingSentAt = now
            }
        }
    }

    // MARK: - Grouping

    private enum DisplayItem: Identifiable {
        case dateSeparator(id: String, label: String)
        case unreadSeparator
        case message(StoredMessage, position: BubblePosition)

        var id: String {
            switch self {
            case .dateSeparator(let id, _): id
            case .unreadSeparator: "unread-separator"
            case .message(let message, _): message.id
            }
        }
    }

    /// Messages within this window and from the same side group together.
    private static let groupWindowMillis: Int64 = 5 * 60 * 1000

    private var displayItems: [DisplayItem] {
        let messages = service.activeMessages
        let readAt = service.conversations.first { $0.id == conversationId }?.readAt ?? 0
        var items: [DisplayItem] = []
        let calendar = Calendar.current
        var unreadSeparatorInserted = false

        for (index, message) in messages.enumerated() {
            let date = Date(timeIntervalSince1970: Double(message.timestamp) / 1000)
            let previous = index > 0 ? messages[index - 1] : nil
            let next = index + 1 < messages.count ? messages[index + 1] : nil

            if previous.map({ !calendar.isDate(
                Date(timeIntervalSince1970: Double($0.timestamp) / 1000),
                inSameDayAs: date) }) ?? true {
                items.append(.dateSeparator(id: "day-\(message.id)", label: Self.dayLabel(date)))
            }

            if !unreadSeparatorInserted && !message.isOutgoing && message.timestamp > readAt {
                items.append(.unreadSeparator)
                unreadSeparatorInserted = true
            }

            let groupsWithPrevious = previous.map { prev -> Bool in
                guard prev.isOutgoing == message.isOutgoing else { return false }
                // In group chats each sender's run is independent.
                if !message.isOutgoing && prev.senderAccount != message.senderAccount { return false }
                // Timestamps are sender-chosen; never trap on overflow.
                let gap = message.timestamp.subtractingReportingOverflow(prev.timestamp)
                return !gap.overflow && gap.partialValue < Self.groupWindowMillis
                    && calendar.isDate(
                        Date(timeIntervalSince1970: Double(prev.timestamp) / 1000),
                        inSameDayAs: date
                    )
            } ?? false
            let groupsWithNext = next.map { nxt -> Bool in
                guard nxt.isOutgoing == message.isOutgoing else { return false }
                if !message.isOutgoing && nxt.senderAccount != message.senderAccount { return false }
                let gap = nxt.timestamp.subtractingReportingOverflow(message.timestamp)
                return !gap.overflow && gap.partialValue < Self.groupWindowMillis
                    && calendar.isDate(
                        Date(timeIntervalSince1970: Double(nxt.timestamp) / 1000),
                        inSameDayAs: date
                    )
            } ?? false

            let position: BubblePosition = switch (groupsWithPrevious, groupsWithNext) {
            case (false, false): .single
            case (false, true): .first
            case (true, true): .middle
            case (true, false): .last
            }
            items.append(.message(message, position: position))
        }
        return items
    }

    private static func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

struct StarredMessagesView: View {
    let service: MessagingService
    let conversationId: String
    let peerName: String

    @Environment(\.dismiss) private var dismiss

    private var starred: [StoredMessage] { service.starredMessages(for: conversationId) }

    var body: some View {
        Group {
            if starred.isEmpty {
                ContentUnavailableView(
                    "No Starred Messages",
                    systemImage: "star",
                    description: Text("Long-press any message and tap Star to bookmark it.")
                )
            } else {
                List(starred) { message in
                    HStack(alignment: .top, spacing: 10) {
                        AvatarView(
                            name: message.isOutgoing ? "You" : peerName,
                            size: 36,
                            imageData: message.isOutgoing
                                ? service.myAvatarData
                                : service.peerAvatarData(forAccount:
                                    service.conversations.first { $0.id == conversationId }?.peerAccount ?? "")
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(message.isOutgoing ? "You" : peerName)
                                    .font(.subheadline.weight(.semibold))
                                Spacer(minLength: 0)
                                Text(Date(timeIntervalSince1970: Double(message.timestamp) / 1000)
                                    .formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(message.body.isEmpty ? "(attachment)" : message.body)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(4)
                        }
                    }
                    .padding(.vertical, 4)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            service.starMessage(message.id, starred: false, in: conversationId)
                        } label: {
                            Label("Unstar", systemImage: "star.slash")
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Starred Messages")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PinnedMessageBanner: View {
    let message: StoredMessage
    let onUnpin: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pin.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
            Text(message.body.isEmpty ? "Pinned message" : message.body)
                .font(.footnote)
                .lineLimit(1)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Button(action: onUnpin) {
                Image(systemName: "xmark")
                    .accessibilityLabel("Unpin message")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

struct ChatPrivacySettingsView: View {
    let service: MessagingService
    let conversation: Conversation

    @State private var isPinned: Bool
    @State private var mediaRequiresBiometric: Bool
    @State private var requireBiometricChat: Bool
    @State private var hidePreviews: Bool
    @State private var disappearingSeconds: Int64
    @State private var notepadEnabled: Bool
    @State private var screenSecurity: Bool

    init(service: MessagingService, conversation: Conversation) {
        self.service = service
        self.conversation = conversation
        _isPinned = State(initialValue: conversation.isPinned)
        _mediaRequiresBiometric = State(initialValue: conversation.mediaRequiresBiometric)
        _requireBiometricChat = State(initialValue: conversation.requireBiometricChat)
        _hidePreviews = State(initialValue: conversation.hidePreviews)
        _disappearingSeconds = State(initialValue: conversation.disappearingSeconds)
        _notepadEnabled = State(initialValue: UserDefaults.standard.bool(forKey: "chat.notepad.\(conversation.id)"))
        _screenSecurity = State(initialValue: conversation.isGroup
            ? (service.group(for: conversation.id)?.screenSecurity ?? true)
            : conversation.screenSecurity)
    }

    private var isGroup: Bool { conversation.isGroup }
    private var canEditGroupScreenSecurity: Bool { service.isAdmin(in: conversation.id) }

    var body: some View {
        Form {
            Section("Conversation") {
                Toggle("Pinned", isOn: $isPinned)
                Toggle("Hide previews in chat list", isOn: $hidePreviews)
            }

            Section("Privacy") {
                Toggle("Require \(BiometricGate.biometryName) for media", isOn: $mediaRequiresBiometric)
                Toggle("Require \(BiometricGate.biometryName) to open chat", isOn: $requireBiometricChat)
            }

            Section {
                if isGroup && !canEditGroupScreenSecurity {
                    HStack {
                        Text("Hide from screenshots")
                        Spacer()
                        Text(screenSecurity ? "On" : "Off").foregroundStyle(.secondary)
                    }
                } else {
                    Toggle("Hide from screenshots", isOn: $screenSecurity)
                }
            } header: {
                Text("Screenshots")
            } footer: {
                if isGroup {
                    Text(canEditGroupScreenSecurity
                         ? "Blanks messages in screenshots and recordings for everyone. Only admins can change this. Relay tries to notify the group when someone takes a screenshot."
                         : "The group admin controls whether messages are hidden from screenshots. Relay tries to notify the group when someone takes a screenshot.")
                } else {
                    Text("Blanks messages in screenshots and recordings. Both people must turn this off to disable it. Relay tries to notify the other person when you take a screenshot.")
                }
            }

            Section("Disappearing Messages") {
                Picker("Timer", selection: $disappearingSeconds) {
                    Text("Off").tag(Int64(0))
                    Text("5 minutes").tag(Int64(5 * 60))
                    Text("1 hour").tag(Int64(60 * 60))
                    Text("8 hours").tag(Int64(8 * 60 * 60))
                    Text("1 day").tag(Int64(24 * 60 * 60))
                    Text("1 week").tag(Int64(7 * 24 * 60 * 60))
                    Text("30 days").tag(Int64(30 * 24 * 60 * 60))
                }
            }

            Section("Features") {
                Toggle("Shared notepad", isOn: $notepadEnabled)
            }
        }
        .navigationTitle("Chat Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: isPinned) { _, value in
            service.setConversationPinned(conversation.id, pinned: value)
        }
        .onChange(of: mediaRequiresBiometric) { _, _ in savePrivacy() }
        .onChange(of: requireBiometricChat) { _, _ in savePrivacy() }
        .onChange(of: hidePreviews) { _, _ in savePrivacy() }
        .onChange(of: disappearingSeconds) { _, value in
            service.setDisappearingSeconds(conversation.id, seconds: value)
        }
        .onChange(of: notepadEnabled) { _, value in
            UserDefaults.standard.set(value, forKey: "chat.notepad.\(conversation.id)")
        }
        .onChange(of: screenSecurity) { _, value in
            if isGroup {
                guard canEditGroupScreenSecurity else { return }
                Task { try? await service.setGroupScreenSecurity(value, conversationId: conversation.id) }
            } else {
                service.setScreenSecurity(value, conversationId: conversation.id)
            }
        }
    }

    private func savePrivacy() {
        service.setConversationPrivacy(
            conversation.id,
            mediaRequiresBiometric: mediaRequiresBiometric,
            requireBiometricChat: requireBiometricChat,
            hidePreviews: hidePreviews
        )
    }
}

enum BubblePosition {
    case single, first, middle, last

    var closesGroup: Bool { self == .single || self == .last }
}

/// Badge next to the peer's name in the title. Unverified peers get none.
private extension VerificationState {
    var titleSymbol: (name: String, tint: Color)? {
        switch self {
        case .verified: ("checkmark.shield.fill", .green)
        case .changed: ("exclamationmark.shield.fill", .orange)
        case .unverified: nil
        }
    }
}
