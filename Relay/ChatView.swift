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
import RelayCore
import RelayKit
import SecureStorage
import AudioToolbox
import SwiftUI
import TipKit
import UIKit
import UniformTypeIdentifiers

struct ChatView: View {
    let service: MessagingService
    let conversationId: String
    var onClose: (() -> Void)? = nil
    /// Message to scroll to on open (e.g. a search hit) instead of the bottom.
    var initialMessageId: String? = nil

    @Environment(ChatAppearance.self) private var appAppearance
    @Environment(\.dynamicTypeSize) private var composerDynamicType
    @State private var dropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotionSetting
    /// The preview for the first link in the draft, built while typing.
    @State private var draftLinkPreview: MessageStore.LinkPreview?
    /// Links whose preview was removed with ×, so it isn't fetched again.
    @State private var dismissedPreviewURLs: Set<String> = []
    @State private var draftPreviewTask: Task<Void, Never>?
    /// Briefly highlighted after jumping to it from a reply.
    @State private var flashedMessageId: String?
    /// The chat's read marker when it was opened. Opening marks it read, so
    /// the live marker would move the "New Messages" line straight away.
    @State private var openedReadAt: Int64?
    /// Mentions of me that have been on screen (or jumped to) this visit.
    @State private var seenMentionIds: Set<String> = []
    /// Unread when opened; shown on the scroll-down button until the bottom.
    @State private var unreadAtOpen = 0
    /// This chat's own theme if it has one, otherwise the app's.
    private var appearance: ChatAppearance { appAppearance.theme(forChat: conversationId) ?? appAppearance }
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
    /// Hold-to-record: when the press began (nil when not holding), how far
    /// the finger has moved, and whether the recording carries on hands-free.
    @State private var holdStartedAt: Date?
    @State private var holdDrag: CGSize = .zero
    @State private var recordingLocked = true
    /// Set when a hold is cancelled by sliding, until the finger lifts.
    @State private var holdCancelled = false
    @State private var micFrame: CGRect = .zero
    /// True while any touch on the composer is down; resets even when the
    /// system cancels the gesture (onEnded isn't called then).
    @GestureState private var composerTouchDown = false
    @State private var recordDenied = false
    @State private var showingVerification = false
    @State private var showingContactCard = false
    @State private var showingGroupInfo = false

    /// Info pages go in a column beside the chat when there's room for both
    /// (an iPad in landscape); otherwise they're sheets.
    private var infoAsColumn: Bool { horizontalSizeClass == .regular && chatWidth >= 800 }
    /// The chat's width before an info column opened (it shrinks once one does).
    @State private var chatWidth: CGFloat = 0

    private var groupInfoPage: some View {
        GroupInfoView(
            service: service,
            conversationId: conversationId,
            ownAccountId: service.credentials.accountId,
            onActivateSearch: {
                showingGroupInfo = false
                inChatSearchActive = true
            }
        )
    }

    private var contactCardPage: some View {
        ContactCardView(service: service, conversationId: conversationId, onActivateSearch: {
            showingContactCard = false
            contactCardClosed()
            inChatSearchActive = true
        })
    }

    /// Settings changed on the contact page apply to the chat.
    private func contactCardClosed() {
        refreshVerification()
        chatAIEnabled = UserDefaults.standard.bool(forKey: "chat.ai.\(conversationId)")
        chatNotepadEnabled = UserDefaults.standard.bool(forKey: "chat.notepad.\(conversationId)")
    }
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
    @State private var inChatMatches: [MessageStore.SearchResult] = []
    @State private var inChatMatchIndex = 0
    @State private var showingDateJump = false
    @State private var dateJumpTarget = Date()
    @State private var dateJumpEarliest = Date()
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
                VStack(spacing: 0) {
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
                                .modifier(PhotoWallpaperLabel())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .id(id)
                        case .unreadSeparator:
                            HStack(spacing: 8) {
                                Rectangle().fill(Color.accentColor.opacity(0.4)).frame(height: 1)
                                Text("New Messages")
                                    .accessibilityAddTraits(.isHeader)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .modifier(PhotoWallpaperLabel())
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
                                .onAppear { if unseenMentionIds.contains(message.id) { seenMentionIds.insert(message.id) } }
                                .transition(Self.arrival(outgoing: message.isOutgoing))
                            }
                        }
                    }
                    if service.typingConversations.contains(conversationId) {
                        TypingIndicatorView(peerName: typingName, imageData: typingAvatar,
                                            label: isGroup ? service.typingDescription(for: conversationId) : nil)
                            .id(Self.typingAnchor)
                            .transition(reduceMotionSetting ? .opacity : .asymmetric(
                                insertion: .scale(scale: 0.6, anchor: .bottomLeading).combined(with: .opacity),
                                removal: .opacity))
                    }
                }
                // Always laid out (it's outside the lazy stack), so scrolling
                // to it reaches the real bottom even when rows above are
                // still estimated.
                Color.clear
                    .frame(height: 1)
                    .id(Self.bottomAnchor)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            // Lays out from the bottom on first show, so the jump there is
            // already done when the messages appear.
            .defaultScrollAnchor(initialMessageId == nil ? .bottom : nil, for: .initialOffset)
            .opacity(initialScrollDone ? 1 : 0)
            .onChange(of: service.messagesLoadedConversationId) { _, loaded in
                guard loaded == conversationId else { return }
                revealInitialPosition(proxy)
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
                if last.isOutgoing {
                    InChatSounds.play(.sent)
                } else if service.isLiveMessage(last.id) {
                    // Not for messages caught up on opening: their push already
                    // sounded.
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    InChatSounds.play(.received)
                }
            }
            // Someone reacted to one of my messages while the chat is open.
            .onChange(of: reactionsOnMyMessages) { old, new in
                guard initialScrollDone, new > old else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            .animation(.spring(duration: 0.3), value: service.typingConversations.contains(conversationId))
            // New messages animate in, but not the first load or older pages.
            .animation(initialScrollDone && !reduceMotionSetting ? .spring(duration: 0.35, bounce: 0.15) : nil,
                       value: service.activeMessages.last?.id)
            .onChange(of: service.typingConversations.contains(conversationId)) { _, isTyping in
                if isTyping { scrollToBottom(proxy) }
            }
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height < 300
            } action: { _, atBottom in
                withAnimation(.spring(duration: 0.2)) { isAtBottom = atBottom }
                if atBottom && initialScrollDone { unreadAtOpen = 0 }
                if atBottom { withAnimation(.spring(duration: 0.3)) { newMessageBanner = nil } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .relayJumpToQuote)) { note in
                guard let quote = note.object as? QuotedMessage else { return }
                jumpToQuoted(quote, proxy: proxy, attemptsLeft: 10)
            }
            .onReceive(NotificationCenter.default.publisher(for: .relayRevealMessage)) { note in
                guard let id = note.object as? String, service.activeMessages.last?.id == id else { return }
                withAnimation(.snappy) { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onAppear {
                if openedReadAt == nil, let conv = conversation {
                    openedReadAt = conv.readAt
                    unreadAtOpen = conv.unreadCount
                }
                scrollViewProxy = proxy
                // Reopening a chat quickly can finish loading before this view
                // appears, so the change above never fires.
                if service.messagesLoadedConversationId == conversationId { revealInitialPosition(proxy) }
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

    /// Scrolls to the first position (applied on the next layout pass), then
    /// shows the messages, so the jump to the bottom isn't visible.
    private func revealInitialPosition(_ proxy: ScrollViewProxy) {
        guard !initialScrollDone else { return }
        DispatchQueue.main.async {
            if let target = initialMessageId,
               service.activeMessages.contains(where: { $0.id == target }) {
                proxy.scrollTo(target, anchor: .center)
            } else if unreadAtOpen > 0, displayItems.contains(where: { if case .unreadSeparator = $0 { true } else { false } }) {
                // Catch up from the first unread message, not the newest.
                proxy.scrollTo("unread-separator", anchor: .top)
            } else {
                scrollToBottom(proxy, animated: false)
            }
            DispatchQueue.main.async { initialScrollDone = true }
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
            if acceptsDrops {
                // One-tap openers, so a new chat doesn't start blank.
                HStack(spacing: 10) {
                    starter("👋", label: "Wave") { quickSend("👋") }
                    starter("Hi!", label: "Say hi") { quickSend("Hi!") }
                    if !isGroup, let username = service.username {
                        starter("📇", label: "Share my contact") {
                            quickSend("Add me on Relay: https://relaymsg.app/add/\(username)")
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func starter(_ text: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(text.count <= 2 ? .title2 : .subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .frame(minWidth: 56, minHeight: 44)
                .glassCompat(in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func quickSend(_ text: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { await service.sendMessage(text, in: conversationId, replyTo: nil, attachments: []) }
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
        .onDrop(of: [.image, .movie, .fileURL, .item], isTargeted: $dropTargeted) { handleDrop($0) }
        .overlay {
            if dropTargeted && acceptsDrops {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        // Bubbles and labels in this chat follow its theme.
        .environment(appearance)
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
                            .submitLabel(.search)
                            .onSubmit { stepInChatMatch(by: -1) }
                        if !inChatMatches.isEmpty, inChatMatches.indices.contains(inChatMatchIndex) {
                            VStack(alignment: .trailing, spacing: 0) {
                                Text("\(inChatMatchIndex + 1) of \(inChatMatches.count)")
                                    .accessibilityLabel("Match \(inChatMatchIndex + 1) of \(inChatMatches.count)")
                                    .font(.caption.monospacedDigit().weight(.medium))
                                Text(Date(timeIntervalSince1970: Double(inChatMatches[inChatMatchIndex].timestamp) / 1000),
                                     format: .dateTime.day().month(.abbreviated))
                                    .font(.caption2)
                            }
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
                        } else if !inChatQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                            Text("No results")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            dateJumpTarget = Date()
                            dateJumpEarliest = (try? service.allMessages(in: conversationId))?.first.map {
                                Date(timeIntervalSince1970: Double($0.timestamp) / 1000)
                            } ?? Date()
                            showingDateJump = true
                        } label: {
                            Image(systemName: "calendar")
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Jump to date")
                        }
                        .buttonStyle(.plain)
                        Button {
                            inChatSearchActive = false
                            inChatQuery = ""
                            inChatMatches = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Close search")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .glassCompat(in: .rect(cornerRadius: 18))
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                    .onChange(of: inChatQuery) { _, _ in runInChatSearch() }
                    .sheet(isPresented: $showingDateJump) { dateJumpSheet }
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
                if !isRequest, initialScrollDone, service.activeMessages.count >= 3,
                   !recorder.isRecording, editingMessage == nil {
                    TipView(RelayTips.chat.currentTip)
                        // A hint shouldn't cover the chat at the largest sizes.
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                }
                if !unseenMentionIds.isEmpty {
                    HStack {
                        Spacer()
                        Button(action: jumpToNextMention) {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "at")
                                    .font(.callout.weight(.bold))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 34, height: 34)
                                    .glassCompat(in: .circle)
                                CountBadge(count: unseenMentionIds.count)
                                    .offset(x: 6, y: -6)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(unseenMentionIds.count == 1 ? "1 mention" : "\(unseenMentionIds.count) mentions")
                        .accessibilityHint("Shows the next message that mentions you")
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .padding(.trailing, 16)
                    }
                    .padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
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
                                let count = max(conversation?.unreadCount ?? 0, unreadAtOpen)
                                if count > 0 {
                                    CountBadge(count: count)
                                        .offset(x: 6, y: -6)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        // The circle is a fixed size; keep the glyph inside it.
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
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
                    // A capsule rather than a full-width strip: a material
                    // background runs into the safe area, under the iPad sidebar.
                    Label("You can't reply to Relay", systemImage: "checkmark.seal.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassCompat(in: .capsule)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 6)
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
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassCompat(in: .capsule)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 6)
                } else if isAnnounceOnlyBlocked {
                    Label("Only admins can send messages", systemImage: "megaphone.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassCompat(in: .capsule)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 6)
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
        // iPhone (and narrow iPad windows): info pages are sheets. Wide iPad
        // windows show them as a column beside the chat instead.
        .sheet(isPresented: Binding(
            get: { showingGroupInfo && !infoAsColumn }, set: { showingGroupInfo = $0 }
        )) {
            groupInfoPage
        }
        .sheet(isPresented: Binding(
            get: { showingContactCard && !infoAsColumn }, set: { showingContactCard = $0 }
        ), onDismiss: contactCardClosed) {
            contactCardPage
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if !(showingContactCard || showingGroupInfo) { chatWidth = width }
        }
        // Only attached in wide windows: on iPhone an inspector becomes a
        // sheet and gets in the way of the chat's push transition.
        .modifier(InfoColumn(enabled: infoAsColumn, isPresented: Binding(
            get: { showingGroupInfo || showingContactCard },
            set: { shown in
                guard !shown else { return }
                showingGroupInfo = false
                if showingContactCard {
                    showingContactCard = false
                    contactCardClosed()
                }
            }
        )) {
            if isGroup { groupInfoPage } else { contactCardPage }
        })
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
        .task(id: service.activeMessages.count) {
            if service.activeMessages.contains(where: { $0.editedAt != nil }) {
                EditedHistoryTip.chatHasEdits = true
            }
        }
        // Recording a voice message shows as typing to the other side.
        .onChange(of: Int(recorder.elapsed)) { _, _ in
            guard recorder.isRecording, !recorder.isReviewing else { return }
            updateTypingState(for: "recording")
        }
        .onChange(of: recorder.isRecording && !recorder.isReviewing) { _, recording in
            if recording { updateTypingState(for: "recording") } else { updateTypingState(for: draft) }
        }
        .onChange(of: draft) { _, newValue in
            updateDraftLinkPreview()
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

    private var reactionsOnMyMessages: Int {
        service.activeMessages.reduce(0) { total, message in
            message.isOutgoing ? total + message.reactions.filter { !$0.isOutgoing }.count : total
        }
    }

    /// A sent message rises from the composer; a received one slides up and
    /// fades in. Removals just fade.
    private static func arrival(outgoing: Bool) -> AnyTransition {
        .asymmetric(
            insertion: outgoing
                ? .move(edge: .bottom).combined(with: .opacity)
                : .offset(y: 14).combined(with: .opacity).combined(with: .scale(scale: 0.97, anchor: .bottomLeading)),
            removal: .opacity
        )
    }

    private static let typingAnchor = "typing-indicator"
    private static let bottomAnchor = "chat-bottom"
    private static let maxDraftLines = 4
    private static let composerControlHeight: CGFloat = 44
    private static let composerAccessoryWidth: CGFloat = 48

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let action = {
            if service.typingConversations.contains(conversationId) {
                proxy.scrollTo(Self.typingAnchor, anchor: .bottom)
            } else if !service.activeMessages.isEmpty {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
        if animated { withAnimation(.snappy) { action() } } else { action() }
        // Rows not yet drawn are measured by estimate, so a jump can land short
        // of the bottom (most with large text); later passes, once those rows
        // have real heights, finish it.
        for delay in animated ? [0.35] : [0.05, 0.2, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { action() }
        }
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
        inChatMatches = service.searchMessages(query: q, in: conversationId)
        inChatMatchIndex = inChatMatches.isEmpty ? 0 : inChatMatches.count - 1
        scrollToMatch()
    }

    /// A calendar from the first message to today; Go shows that day.
    private var dateJumpSheet: some View {
        NavigationStack {
            DatePicker("Date", selection: $dateJumpTarget,
                       in: Calendar.current.startOfDay(for: dateJumpEarliest)...Date(),
                       displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding(.horizontal)
                .navigationTitle("Jump to Date")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingDateJump = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Go") {
                            showingDateJump = false
                            jumpToDate(dateJumpTarget)
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }

    /// Shows the first message sent on or after the day, loading older
    /// pages until it's there.
    private func jumpToDate(_ date: Date) {
        let start = Int64(Calendar.current.startOfDay(for: date).timeIntervalSince1970 * 1000)
        let all = (try? service.allMessages(in: conversationId)) ?? []
        guard let target = all.first(where: { $0.timestamp >= start && !$0.isDeleted }) ?? all.last else { return }
        func attempt(_ left: Int) {
            if service.activeMessages.contains(where: { $0.id == target.id }) {
                withAnimation(.snappy) { scrollViewProxy?.scrollTo(target.id, anchor: .top) }
                flashMessage(target.id)
            } else if left > 0, service.hasEarlierMessages {
                service.loadEarlierMessages()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { attempt(left - 1) }
            }
        }
        attempt(40)
    }

    private func stepInChatMatch(by delta: Int) {
        guard !inChatMatches.isEmpty else { return }
        inChatMatchIndex = (inChatMatchIndex + delta + inChatMatches.count) % inChatMatches.count
        scrollToMatch()
    }

    /// Older matches may be outside the loaded page: pages load until the
    /// match is on screen.
    private func scrollToMatch(attemptsLeft: Int = 20) {
        guard inChatMatchIndex < inChatMatches.count else { return }
        let id = inChatMatches[inChatMatchIndex].messageId
        if service.activeMessages.contains(where: { $0.id == id }) {
            withAnimation { scrollViewProxy?.scrollTo(id, anchor: .center) }
        } else if attemptsLeft > 0, service.hasEarlierMessages {
            service.loadEarlierMessages()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                scrollToMatch(attemptsLeft: attemptsLeft - 1)
            }
        }
    }

    /// Briefly highlights a message the chat just scrolled to.
    private func flashMessage(_ id: String) {
        withAnimation(.easeOut(duration: 0.2)) { flashedMessageId = id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeOut(duration: 0.4)) {
                if flashedMessageId == id { flashedMessageId = nil }
            }
        }
    }

    /// Scrolls to the message a reply quotes and highlights it for a moment,
    /// loading older pages until it's found (or there's nothing older).
    private func jumpToQuoted(_ quote: QuotedMessage, proxy: ScrollViewProxy, attemptsLeft: Int) {
        let me = service.credentials.accountId
        let target = service.activeMessages.last { message in
            message.timestamp == quote.targetTimestamp
                && (quote.author == me ? message.isOutgoing : message.senderAccount == quote.author || !message.isOutgoing)
        }
        if let target {
            withAnimation(.snappy) { proxy.scrollTo(target.id, anchor: .center) }
            withAnimation(.easeOut(duration: 0.2)) { flashedMessageId = target.id }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                withAnimation(.easeOut(duration: 0.4)) {
                    if flashedMessageId == target.id { flashedMessageId = nil }
                }
            }
        } else if attemptsLeft > 0, service.hasEarlierMessages {
            service.loadEarlierMessages()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                jumpToQuoted(quote, proxy: proxy, attemptsLeft: attemptsLeft - 1)
            }
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    private func isCurrentSearchMatch(_ message: StoredMessage) -> Bool {
        // Also lights up the message being edited.
        if message.id == flashedMessageId || message.id == editingMessage?.id { return true }
        guard inChatSearchActive, inChatMatches.indices.contains(inChatMatchIndex) else { return false }
        return inChatMatches[inChatMatchIndex].messageId == message.id
    }

    private func beginReply(_ message: StoredMessage) {
        replyingTo = message
        composerFocused = true
        SwipeToReplyTip().invalidate(reason: .actionPerformed)
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
            FormatButton(symbol: "eye.slash", tip: "Spoiler") {
                composerContext.applyFormat(prefix: "||", suffix: "||")
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
            if let draftLinkPreview, editingMessage == nil {
                ComposerLinkPreview(preview: draftLinkPreview) {
                    withAnimation(.spring(duration: 0.25)) {
                        dismissedPreviewURLs.insert(draftLinkPreview.url)
                        self.draftLinkPreview = nil
                    }
                }
                .padding(.bottom, 6)
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
                            // Hold to record (release sends, slide left cancels,
                            // slide up locks); a tap records hands-free. The
                            // gesture lives on the composer so it survives the
                            // switch to the recording bar.
                            composerAccessoryIcon("mic.fill")
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.composerSpace)) } action: {
                                    micFrame = $0
                                }
                                .accessibilityElement()
                                .accessibilityLabel("Record voice message")
                                .accessibilityHint("Hold to record, or double-tap to record hands-free.")
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { recordingLocked = true; startRecording() }
                                .transition(.opacity)
                        }

                        FormattingTextEditor(
                            text: $draft,
                            placeholder: isNoteToSelf ? "Write a note…"
                                : composerDynamicType.isAccessibilitySize ? "Message" : "Message \(peerName)…",
                            maxLines: Self.maxDraftLines,
                            context: composerContext,
                            isFocused: $composerFocused,
                            incognito: incognitoKeyboard,
                            onSubmit: { send() }
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
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                        }
                    }
                    .animation(.easeOut(duration: 0.12), value: showRecordButton)
                    .animation(.spring(duration: 0.3, bounce: 0.35), value: showSendButton)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                }
            }
            .coordinateSpace(.named(Self.composerSpace))
            .simultaneousGesture(holdToRecordGesture)
            .onChange(of: composerTouchDown) { _, down in
                // The hold was cancelled (e.g. by the microphone prompt):
                // keep the recording hands-free rather than stuck mid-hold.
                guard !down, holdStartedAt != nil else { return }
                holdStartedAt = nil
                holdDrag = .zero
                withAnimation(.spring(duration: 0.3)) { recordingLocked = true }
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

    private static let composerSpace = "composer"

    private var holdToRecordGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.composerSpace))
            .updating($composerTouchDown) { _, down, _ in down = true }
            .onChanged { value in
                if holdStartedAt == nil {
                    guard !holdCancelled, showRecordButton, !recorder.isRecording,
                          micFrame.contains(value.startLocation) else { return }
                    holdStartedAt = Date()
                    holdDrag = .zero
                    recordingLocked = false
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    startRecording()
                    return
                }
                guard !recordingLocked else { return }
                holdDrag = value.translation
                if value.translation.height < -80 {
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    withAnimation(.spring(duration: 0.3)) { recordingLocked = true; holdDrag = .zero }
                } else if value.translation.width < -55 {
                    // The mic sits near the left edge, so a short slide cancels.
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    recorder.cancel()
                    holdStartedAt = nil
                    holdDrag = .zero
                    holdCancelled = true
                }
            }
            .onEnded { _ in
                defer { holdCancelled = false }
                guard let started = holdStartedAt else { return }
                holdStartedAt = nil
                holdDrag = .zero
                if recordingLocked { return }
                // A quick tap: carry on hands-free, as tapping the mic used to.
                if Date().timeIntervalSince(started) < 0.35 {
                    withAnimation(.spring(duration: 0.3)) { recordingLocked = true }
                    return
                }
                finishRecording()
            }
    }

    /// Replaces the compose row while a voice message is being recorded.
    @ViewBuilder
    private var recordingBar: some View {
        if recorder.isReviewing {
            reviewRecordingBar
        } else if !recordingLocked {
            holdingRecordingBar
        } else {
            lockedRecordingBar
        }
    }

    /// While the mic is held: slide left to cancel, up to lock. The red
    /// mic sits where the finger is, at the left.
    private var holdingRecordingBar: some View {
        let slide = min(0, holdDrag.width)
        let lift = min(0, holdDrag.height)
        let cancelProgress = min(1, Double(-slide) / 55)
        return HStack(alignment: .bottom, spacing: 6) {
            Image(systemName: cancelProgress > 0.8 ? "trash.fill" : "mic.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: Self.composerAccessoryWidth, height: Self.composerControlHeight)
                .background(Color.red, in: .capsule)
                .scaleEffect(1.12 + CGFloat(recorder.levels.last ?? 0) * 0.2)
                .animation(.easeOut(duration: 0.1), value: recorder.levels.last)
                .offset(x: slide * 0.5, y: lift * 0.4)
                .overlay(alignment: .top) {
                    VStack(spacing: 4) {
                        Image(systemName: lift < -40 ? "lock.fill" : "lock.open.fill")
                            .contentTransition(.symbolEffect(.replace))
                        Image(systemName: "chevron.up")
                            .font(.caption2.weight(.bold))
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
                    .frame(width: 40)
                    .glassCompat(in: .capsule)
                    .offset(y: -82 + lift * 0.3)
                }
                .zIndex(1)

            HStack(spacing: 10) {
                RecordingDot(isPaused: false)
                Text(formatDuration(recorder.elapsed))
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .contentTransition(.numericText())
                RecordingLevels(levels: recorder.levels)
                    .frame(height: 22)
                Label("Slide to cancel", systemImage: "chevron.left")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .opacity(1 - cancelProgress)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: Self.composerControlHeight)
            .glassCompat(in: .capsule)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording")
        .accessibilityValue(formatDuration(recorder.elapsed))
        .transition(.opacity)
    }

    /// Stopped: play it back, then send or delete.
    private var reviewRecordingBar: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Button {
                recorder.cancel()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: Self.composerAccessoryWidth, height: Self.composerControlHeight)
                    .contentShape(.capsule)
                    .glassCompat(in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete recording")

            HStack(spacing: 10) {
                Button {
                    recorder.togglePreview()
                } label: {
                    Image(systemName: recorder.isPreviewPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color(.label))
                        .frame(width: 30, height: 30)
                        .contentShape(.circle)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(recorder.isPreviewPlaying ? "Pause" : "Play recording")
                RecordingReview(levels: recorder.allLevels, progress: recorder.previewProgress)
                    .frame(height: 22)
                    .accessibilityHidden(true)
                Text(formatDuration(recorder.elapsed))
                    .font(.subheadline.monospacedDigit().weight(.medium))
            }
            .padding(.leading, 7)
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, minHeight: Self.composerControlHeight)
            .glassCompat(in: .capsule)

            Button {
                finishRecording()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: Self.composerAccessoryWidth, height: Self.composerControlHeight)
                    .contentShape(.capsule)
                    .background(Color.accentColor, in: .capsule)
                    .glassCompat(in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send voice message")
        }
        .transition(.opacity)
    }

    /// Hands-free recording (tapped, or slid up to lock).
    private var lockedRecordingBar: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Button {
                recorder.cancel()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: Self.composerAccessoryWidth, height: Self.composerControlHeight)
                    .contentShape(.capsule)
                    .glassCompat(in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete recording")

            HStack(spacing: 10) {
                RecordingDot(isPaused: recorder.isPaused)
                Text(formatDuration(recorder.elapsed))
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .contentTransition(.numericText())
                RecordingLevels(levels: recorder.levels)
                    .frame(height: 22)
                    .accessibilityHidden(true)
                Button {
                    recorder.togglePause()
                } label: {
                    Image(systemName: recorder.isPaused ? "mic.fill" : "pause.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(recorder.isPaused ? .red : Color(.label))
                        .frame(width: 30, height: 30)
                        .contentShape(.circle)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(recorder.isPaused ? "Resume recording" : "Pause recording")
                Button {
                    withAnimation(.spring(duration: 0.3)) { recorder.stopForReview() }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.red)
                        .frame(width: 30, height: 30)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop and listen")
            }
            .padding(.leading, 14)
            .padding(.trailing, 7)
            .frame(maxWidth: .infinity, minHeight: Self.composerControlHeight)
            .glassCompat(in: .capsule)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(recorder.isPaused ? "Recording paused" : "Recording")
            .accessibilityValue(formatDuration(recorder.elapsed))

            Button {
                finishRecording()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: Self.composerAccessoryWidth, height: Self.composerControlHeight)
                    .contentShape(.capsule)
                    .background(Color.accentColor, in: .capsule)
                    .glassCompat(in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send voice message")
        }
        .transition(.opacity)
    }

    private func composerAccessoryIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(Color(.label))
            .frame(width: Self.composerAccessoryWidth, height: Self.composerControlHeight)
            .contentShape(.capsule)
            .glassCompat(in: .capsule)
            .contentShape(.hoverEffect, .capsule)
            .hoverEffect(.highlight)
    }

    private var composerSendIcon: some View {
        Image(systemName: composerActionSymbol)
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: Self.composerAccessoryWidth, height: Self.composerControlHeight)
            .contentShape(.capsule)
            .background(Color.accentColor, in: .capsule)
            .glassCompat(in: .capsule)
            .contentShape(.hoverEffect, .capsule)
            .hoverEffect(.highlight)
    }

    /// Replaces the composer for a chat someone else started.
    private var messageRequestBar: some View {
        let isGroup = conversation?.isGroup ?? false
        _ = service.scamFlagsRevision // refresh when a check finishes
        let scam = service.scamFlag(forConversation: conversationId)
        return VStack(spacing: 12) {
            if scam != nil {
                // The whole request, not just one message: a stranger whose
                // messages match a scam.
                VStack(alignment: .leading, spacing: 4) {
                    Label("This request looks like a scam", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text("\(peerName) isn't someone you chat with, and their messages match common scams. Don't send money, codes or personal details. You can block and report them below.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.orange.opacity(0.12), in: .rect(cornerRadius: 12))
            }
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
        // A rounded card, not a strip: a material background would run into
        // the safe area, under the iPad sidebar.
        .glassCompat(in: .rect(cornerRadius: 24))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
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

    /// Whether this chat currently has a composer to attach to.
    private var acceptsDrops: Bool {
        !isRelayOfficial && !isRequest && blockedPeer == nil && !isAnnounceOnlyBlocked
            && !isSelectingMessages && !recorder.isRecording && !isNoteToSelf
    }

    /// Photos, videos and files dropped onto the chat (iPad drag and drop)
    /// become pending attachments, prepared the same way as picked ones.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard acceptsDrops, !providers.isEmpty else { return false }
        Task {
            var media: [MessagingService.PendingAttachment] = []
            var file: MessagingService.PendingAttachment?
            for provider in providers.prefix(10) {
                if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    if let data = await Self.loadFile(provider, type: .movie),
                       let clean = await MediaSanitizer.video(data.data, contentType: data.mime ?? "video/mp4") {
                        let mime = data.mime ?? "video/mp4"
                        media.append(.init(data: clean, contentType: mime,
                                           filename: mime == "video/quicktime" ? "video.mov" : "video.mp4",
                                           width: 0, height: 0))
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    let isGIF = provider.hasItemConformingToTypeIdentifier(UTType.gif.identifier)
                    if let data = await Self.loadData(provider, type: .image),
                       let clean = MediaSanitizer.photo(data) {
                        media.append(.init(data: clean.data, contentType: clean.contentType,
                                           filename: isGIF ? "image.gif" : nil,
                                           width: clean.width, height: clean.height))
                    }
                } else if file == nil, let data = await Self.loadFile(provider, type: .item) {
                    file = .init(data: data.data, contentType: data.mime ?? "application/octet-stream",
                                 filename: data.name, width: 0, height: 0)
                }
            }
            if !media.isEmpty {
                pendingAttachments = media
                if !media.allSatisfy({ $0.contentType.hasPrefix("image/") }) { viewOnce = false }
            } else if let file {
                pendingAttachments = [file]
                viewOnce = false
            }
        }
        return true
    }

    private static func loadData(_ provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(for: type) { data, _ in continuation.resume(returning: data) }
        }
    }

    /// Reads the file before the provider deletes its temporary copy.
    private static func loadFile(_ provider: NSItemProvider, type: UTType) async -> (data: Data, mime: String?, name: String)? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                guard let url, let data = try? Data(contentsOf: url) else {
                    continuation.resume(returning: nil)
                    return
                }
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                continuation.resume(returning: (data, mime, provider.suggestedName.map { name in
                    url.pathExtension.isEmpty ? name : "\(name).\(url.pathExtension)"
                } ?? url.lastPathComponent))
            }
        }
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
        HoldToRecordTip().invalidate(reason: .actionPerformed)
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
        if editingMessage == nil { ReviewPrompt.noteMessageSent() }
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
        let preview = draftLinkPreview.flatMap { text.contains($0.url) ? $0 : nil }
        draftLinkPreview = nil
        draftPreviewTask?.cancel()
        draft = ""
        replyingTo = nil
        viewOnce = false
        clearPendingAttachments()
        Task { await service.sendMessage(text, in: conversationId, replyTo: reply, attachments: attachments, linkPreview: preview) }
    }

    /// Builds a preview for the draft's first link, after typing pauses.
    private func updateDraftLinkPreview() {
        let link = draft.firstURLText
        if draftLinkPreview?.url == link, link != nil { return }
        draftPreviewTask?.cancel()
        guard let link, !dismissedPreviewURLs.contains(link), !isRequest, editingMessage == nil else {
            if draftLinkPreview != nil { withAnimation(.spring(duration: 0.25)) { draftLinkPreview = nil } }
            return
        }
        draftPreviewTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            let isRelayLink = URL(string: link).flatMap(RelayLink.init) != nil
            let built = isRelayLink
                ? await RelayLink.preview(for: link, service: service)
                : await LinkPreviewBuilder.build(for: link)
            guard !Task.isCancelled, let preview = built,
                  !Task.isCancelled, draft.firstURLText == link
            else { return }
            withAnimation(.spring(duration: 0.25)) { draftLinkPreview = preview }
        }
    }

    /// Throttled typing broadcast: `.started` at most every few seconds while
    /// the field is non-empty, `.stopped` as soon as it empties.
    /// Unread messages that mention me and haven't been on screen yet,
    /// oldest first.
    private var unseenMentionIds: [String] {
        guard let username = service.username, let readAt = openedReadAt else { return [] }
        return service.activeMessages.compactMap { message in
            guard !message.isOutgoing, !message.isDeleted, message.timestamp > readAt,
                  !seenMentionIds.contains(message.id),
                  Mentions.contains(message.body, username: username) else { return nil }
            return message.id
        }
    }

    private func jumpToNextMention() {
        guard let next = unseenMentionIds.first, let proxy = scrollViewProxy else { return }
        seenMentionIds.insert(next)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.snappy) { proxy.scrollTo(next, anchor: .center) }
        flashMessage(next)
    }

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
        let readAt = openedReadAt ?? service.conversations.first { $0.id == conversationId }?.readAt ?? 0
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
        // A floating card, kept inside the chat (a full-width bar ran under
        // the iPad sidebar).
        .glassCompat(in: .rect(cornerRadius: 16))
        .padding(.horizontal, 10)
        .padding(.top, 4)
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

// MARK: - Message row (gestures)

/// Wraps a bubble with swipe-to-reply plus custom quick reactions and actions.
private struct MessageRow: View {
    /// Bubbles never grow past this, so lines stay readable on iPad.
    /// Space kept on the far side of a bubble; less at accessibility text
    /// sizes so the text gets more of the row.
    static func sideGap(_ size: DynamicTypeSize) -> CGFloat { size.isAccessibilitySize ? 12 : 56 }

    static let maxBubbleWidth: CGFloat = 560
    let message: StoredMessage
    let position: BubblePosition
    let peerName: String
    let service: MessagingService
    let conversationId: String
    let isGroup: Bool
    let onReply: () -> Void
    let onForward: () -> Void
    let onEdit: () -> Void
    let onInfo: () -> Void
    let onUpdatePin: () -> Void
    var isCurrentSearchMatch = false
    var isSelectionMode = false
    var isSelected = false
    let onToggleSelection: () -> Void
    let onBeginSelection: () -> Void

    @Environment(ChatAppearance.self) private var appearance
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var confirmDelete = false
    @State private var scamKind: ScamKind?
    /// Earlier versions of an edited message, oldest first, while shown
    /// above the current text. Kept here, outside the hosted bubble, so the
    /// row resizes when they appear.
    @State private var editVersions: [String]?
    @State private var spoilersRevealed = false
    /// Result of Make Sticker, shown as an alert.
    @State private var stickerResult: String?

    /// Lifts the photo's subject into a sticker in My Stickers. Photos
    /// flagged as sensitive are left alone.
    private func makeSticker(from photo: StoredAttachment) {
        Task {
            // Same gate as viewing the photo when this chat locks its media.
            if service.conversations.first(where: { $0.id == conversationId })?.mediaRequiresBiometric ?? true {
                guard await BiometricGate.authenticate(reason: "Make a sticker from this photo.") else { return }
            }
            var data = service.attachmentPlaintext(photo)
            if data == nil {
                await service.downloadAttachment(photo, in: conversationId)
                data = service.attachmentPlaintext(photo)
            }
            guard let data else { stickerResult = "This photo isn't available."; return }
            if SensitiveContent.isEnabled, await SensitiveContent.isSensitive(imageData: data, cacheKey: photo.id) {
                stickerResult = "This photo can't be made into a sticker."
                return
            }
            guard let png = await StickerRenderer.subjectPNG(from: data) else {
                stickerResult = "Couldn't find a subject to cut out of this photo."
                return
            }
            MyStickerStore.shared.add(png)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            stickerResult = "Added to My Stickers."
        }
    }

    private func revealSpoilers() {
        withAnimation(.easeOut(duration: 0.25)) { spoilersRevealed = true }
    }

    private func toggleEditHistory() {
        EditedHistoryTip().invalidate(reason: .actionPerformed)
        withAnimation(.snappy) {
            editVersions = editVersions == nil ? service.editHistory(of: message.id).map(\.body) : nil
        }
        if editVersions != nil {
            let id = message.id
            Task {
                try? await Task.sleep(for: .milliseconds(80))
                NotificationCenter.default.post(name: .relayRevealMessage, object: id)
            }
        }
    }

    private var bubble: some View {
        MessageBubble(
            message: message, position: position, peerName: peerName,
            service: service, conversationId: conversationId, isGroup: isGroup,
            isCurrentSearchMatch: isCurrentSearchMatch, onInfo: onInfo,
            editVersions: editVersions, onToggleEditHistory: toggleEditHistory,
            spoilersRevealed: spoilersRevealed, onRevealSpoilers: revealSpoilers
        )
    }

    /// Plain text with nothing tappable inside, so VoiceOver can read it as
    /// one element with reply/forward actions.
    private var isPlainText: Bool {
        message.attachments.isEmpty && !message.isDeleted && message.body.firstURL == nil
            && !message.body.hasPrefix("__") && !message.body.hasPrefix("~once~")
            && !message.body.hasPrefix("call:") && message.body != MessagingService.stickerMarker
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
                .onChange(of: message.editedAt) { editVersions = nil }
                .alert(stickerResult ?? "", isPresented: Binding(
                    get: { stickerResult != nil }, set: { if !$0 { stickerResult = nil } }
                )) {
                    Button("OK", role: .cancel) {}
                }
                .accessibilityElement(children: isPlainText && !isSelectionMode ? .combine : .contain)
                // The long-press menu isn't reachable with VoiceOver; every action
                // and reaction is offered in the actions rotor instead.
                .accessibilityActions {
                    if !isSelectionMode && !message.isDeleted {
                        ForEach(menuActions.filter { $0.label != "Reply" && $0.label != "Forward" }) { action in
                            Button(action.label) { action.action() }
                        }
                        ForEach(quickReactions, id: \.self) { emoji in
                            Button("React \(emoji)") { service.toggleReaction(emoji, on: message) }
                        }
                    }
                }
            // Below the row, not in the bubble: the avatar stays by the message
            // and a long-press menu shows only the message.
            if let scamKind, !message.isDeleted, !isSelectionMode {
                ScamWarningView(kind: scamKind, message: message, service: service,
                                senderAccount: rowSenderAccount, senderName: rowAvatarName) {
                    withAnimation { self.scamKind = nil }
                }
                // Lined up with the bubble: past the avatar, short of the far edge.
                .padding(.leading, 36)
                .padding(.trailing, 40)
                .frame(maxWidth: Self.maxBubbleWidth + 76, alignment: .leading)
                .transition(.opacity)
            }
        }
            // Checked once per incoming message, on the device (ScamCheck.swift).
            .task(id: message.id) {
                guard !message.isOutgoing, !message.isDeleted else { return }
                if let known = service.scamWarning(for: message.id) {
                    scamKind = known
                } else if let found = await service.checkForScam(message, in: conversationId) {
                    withAnimation { scamKind = found }
                }
            }
            .accessibilityAction(named: "Reply") { onReply() }
            .accessibilityAction(named: "Forward") { onForward() }
            .padding(.vertical, isSelected ? 2 : 0)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .padding(.horizontal, -4)
                        .transition(.opacity)
                }
            }
            .confirmationDialog("Delete this message?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    service.deleteMessage(message.id, in: conversationId)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if isSelectionMode {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 34, height: 34)
                    .glassCompat(in: .circle)
                    .transition(.opacity)
                bubble
                    .contentShape(.rect)
                    .onTapGesture { onToggleSelection() }
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityHint("Selects this message")
            }
        } else if message.isDeleted {
            bubble
        } else {
            // UIKit context menu with a reaction bar kept in sync through the
            // interaction's willDisplay/willEnd callbacks. The row handles
            // alignment so the menu's source view is just the bubble and the menu
            // lands on the message's side. Double-tap and swipe-to-reply live in
            // the UIKit layer so they don't fight the interaction.
            HStack(alignment: .bottom, spacing: 8) {
                if message.isOutgoing {
                    Spacer(minLength: MessageRow.sideGap(dynamicTypeSize))
                } else if position.closesGroup {
                    AvatarView(name: rowAvatarName, size: 28, imageData: rowAvatarData)
                } else {
                    Color.clear.frame(width: 28, height: 1)
                }

                NativeMenuBubble(
                    bubble: AnyView(
                        MessageBubble(
                            message: message, position: position, peerName: peerName,
                            service: service, conversationId: conversationId, isGroup: isGroup,
                            isCurrentSearchMatch: isCurrentSearchMatch, onInfo: onInfo,
                            editVersions: editVersions, onToggleEditHistory: toggleEditHistory,
                            spoilersRevealed: spoilersRevealed, onRevealSpoilers: revealSpoilers,
                            embedsAlignment: false
                        )
                        .environment(appearance)
                    ),
                    isOutgoing: message.isOutgoing,
                    reactions: quickReactions,
                    currentReaction: message.reactions.first(where: \.isOutgoing)?.emoji,
                    actions: menuActions,
                    onReact: { emoji in
                        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                        service.toggleReaction(emoji, on: message)
                    },
                    onDoubleTap: {
                        DoubleTapReactTip().invalidate(reason: .actionPerformed)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        service.toggleReaction("❤️", on: message)
                    },
                    onReply: onReply
                )
                // Readable line length on iPad and wide windows.
                .frame(maxWidth: Self.maxBubbleWidth, alignment: message.isOutgoing ? .trailing : .leading)

                if !message.isOutgoing { Spacer(minLength: MessageRow.sideGap(dynamicTypeSize)) }
            }
        }
    }

    // Account whose avatar is shown beside incoming bubbles.
    private var rowSenderAccount: String? {
        if isGroup { return message.senderAccount }
        return service.conversations.first { $0.id == conversationId }?.peerAccount
    }
    private var rowAvatarName: String {
        isGroup ? service.displayName(forAccount: message.senderAccount ?? "") : peerName
    }
    private var rowAvatarData: Data? {
        rowSenderAccount.flatMap { service.peerAvatarData(forAccount: $0) }
    }

    /// Action menu contents; reactions are in the separate bar.
    private var menuActions: [MessageActionSpec] {
        var items: [MessageActionSpec] = []
        if message.isOutgoing && message.status == .failed {
            items.append(.init(label: "Retry", icon: "arrow.clockwise") {
                Task { await service.retrySend(message) }
            })
        }
        items.append(.init(label: "Reply", icon: "arrowshape.turn.up.left") { onReply() })
        if message.isOutgoing && message.attachments.isEmpty {
            items.append(.init(label: "Edit", icon: "pencil") { onEdit() })
        }
        let isViewOnce = message.body.hasPrefix(MessagingService.viewOncePrefix)
        if !message.body.isEmpty && !isViewOnce {
            items.append(.init(label: "Copy", icon: "doc.on.doc") { SecurePasteboard.copy(message.body) })
        }
        if (!message.body.isEmpty || !message.attachments.isEmpty) && !isViewOnce && !message.isDeleted {
            items.append(.init(label: "Forward", icon: "arrowshape.turn.up.right") { onForward() })
        }
        items.append(.init(label: message.isStarred ? "Unstar" : "Star",
                           icon: message.isStarred ? "star.slash" : "star") {
            service.starMessage(message.id, starred: !message.isStarred, in: conversationId)
        })
        items.append(.init(label: message.isPinned ? "Unpin" : "Pin",
                           icon: message.isPinned ? "pin.slash" : "pin") {
            service.pinMessage(message.id, pinned: !message.isPinned, in: conversationId)
            onUpdatePin()
        })
        if !isViewOnce, !message.isDeleted, message.body != MessagingService.stickerMarker,
           let photo = message.attachments.first(where: \.isImage) {
            items.append(.init(label: "Make Sticker", icon: "face.dashed") { makeSticker(from: photo) })
        }
        items.append(.init(label: "Info", icon: "info.circle") { onInfo() })
        items.append(.init(label: "Select", icon: "checkmark.circle") { onBeginSelection() })
        if service.canUnsend(message) {
            items.append(.init(label: "Unsend for Everyone", icon: "arrow.uturn.backward", role: .destructive) {
                service.unsend(message)
            })
        }
        items.append(.init(label: "Delete", icon: "trash", role: .destructive) { confirmDelete = true })
        return items
    }
}

// MARK: - Bubble

private struct MessageBubble: View {
    @Environment(\.relayIsMessageRequest) private var inRequestChat
    let message: StoredMessage
    let position: BubblePosition
    let peerName: String
    let service: MessagingService
    let conversationId: String
    let isGroup: Bool
    var isCurrentSearchMatch = false
    var onInfo: () -> Void = {}
    /// Earlier versions to show above the text (nil while hidden).
    var editVersions: [String]? = nil
    var onToggleEditHistory: () -> Void = {}
    /// Spoilers in this message have been tapped open (kept by the row, as
    /// revealing can change the bubble's size).
    var spoilersRevealed = false
    var onRevealSpoilers: () -> Void = {}
    /// When false, renders only the bubble core, without spacers or avatar, so
    /// the row can align it and use it as the context-menu source view.
    var embedsAlignment: Bool = true

    @Environment(ChatAppearance.self) private var appearance
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Chat-level link opener (in-app Safari for http/https), used after the
    /// user confirms a link from a received message.
    @Environment(\.openURL) private var parentOpenURL
    @State private var reactionDetailEmoji: String?
    @State private var pendingLinkURL: URL?

    private var showsSenderLabel: Bool {
        isGroup && !message.isOutgoing && (position == .single || position == .first)
            && !(message.senderAccount ?? "").isEmpty
    }

    private var isJumbo: Bool {
        message.replyTo == nil && message.body.isJumbomojiCandidate && message.attachments.isEmpty
    }

    /// The account whose avatar/name belongs on this incoming bubble: the
    /// sender in a group, otherwise the 1:1 peer.
    private var senderAccount: String? {
        if isGroup { return message.senderAccount }
        return service.conversations.first { $0.id == conversationId }?.peerAccount
    }
    private var avatarName: String {
        isGroup ? service.displayName(forAccount: message.senderAccount ?? "") : peerName
    }
    private var avatarData: Data? {
        senderAccount.flatMap { service.peerAvatarData(forAccount: $0) }
    }

    private var mediaRequiresBiometric: Bool {
        service.conversations.first { $0.id == conversationId }?.mediaRequiresBiometric ?? true
    }

    private var isViewOnce: Bool { message.body.hasPrefix("~once~") }

    var body: some View {
        Group {
            if embedsAlignment {
                HStack(alignment: .bottom, spacing: 8) {
                    if message.isOutgoing {
                        Spacer(minLength: MessageRow.sideGap(dynamicTypeSize))
                    } else if position.closesGroup {
                        // Avatar only on the last bubble of a run.
                        AvatarView(name: avatarName, size: 28, imageData: avatarData)
                    } else {
                        Color.clear.frame(width: 28, height: 1)
                    }

                    coreColumn
                        .frame(maxWidth: MessageRow.maxBubbleWidth,
                               alignment: message.isOutgoing ? .trailing : .leading)

                    if !message.isOutgoing { Spacer(minLength: MessageRow.sideGap(dynamicTypeSize)) }
                }
            } else {
                coreColumn
            }
        }
        .background {
            if isCurrentSearchMatch {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
                    }
                    .padding(.horizontal, 34)
                    .transition(.opacity)
            }
        }
        .animation(.spring(duration: 0.25), value: isCurrentSearchMatch)
        .sheet(item: Binding(
            get: { reactionDetailEmoji.map { ReactionEmojiID(emoji: $0) } },
            set: { reactionDetailEmoji = $0?.emoji }
        )) { item in
            ReactionAttributionSheet(
                emoji: item.emoji,
                reactions: message.reactions.filter { $0.emoji == item.emoji },
                service: service
            )
            .presentationDetents([.fraction(0.4)])
        }
        // Links in received messages never open directly: markdown lets a sender
        // show one URL and link another, so the real host is confirmed first.
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == Self.spoilerScheme {
                onRevealSpoilers()
                return .handled
            }
            guard !message.isOutgoing else { return .systemAction }
            pendingLinkURL = url
            return .handled
        })
        .confirmationDialog(
            pendingLinkURL.map { "Open link to \(LinkConfirmation.displayHost(for: $0))?" } ?? "",
            isPresented: Binding(
                get: { pendingLinkURL != nil },
                set: { if !$0 { pendingLinkURL = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let url = pendingLinkURL {
                Button("Open") {
                    pendingLinkURL = nil
                    parentOpenURL(url)
                }
                Button("Copy Link") {
                    pendingLinkURL = nil
                    SecurePasteboard.copy(url.absoluteString)
                }
            }
            Button("Cancel", role: .cancel) { pendingLinkURL = nil }
        } message: {
            if let url = pendingLinkURL {
                Text(LinkConfirmation.message(for: url))
            }
        }
    }

    /// Sender label, bubble and reaction badges, without alignment spacers.
    private var coreColumn: some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 3) {
            if showsSenderLabel {
                let name = service.displayName(forAccount: message.senderAccount ?? "")
                Text(name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AvatarView.color(for: name))
                    .modifier(PhotoWallpaperLabel())
                    .padding(.leading, 10)
            }
            if dynamicTypeSize.isAccessibilitySize, !message.reactions.isEmpty {
                // Large reactions would cover the time; they go under the bubble.
                VStack(alignment: message.isOutgoing ? .leading : .trailing, spacing: 4) {
                    bubbleContent
                    ReactionBadges(chips: reactionChips, onTap: { reactionDetailEmoji = $0 })
                }
            } else {
                bubbleContent
                    .overlay(alignment: message.isOutgoing ? .bottomLeading : .bottomTrailing) {
                        if !message.reactions.isEmpty {
                            ReactionBadges(chips: reactionChips, onTap: { reactionDetailEmoji = $0 })
                                .offset(x: message.isOutgoing ? -6 : 6, y: 14)
                        }
                    }
                    .padding(.bottom, message.reactions.isEmpty ? 0 : 16)
            }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if message.isDeleted {
            HStack(spacing: 5) {
                Image(systemName: "slash.circle")
                Text(message.isOutgoing ? "You deleted this message" : "This message was deleted")
                    .italic()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4]))
            }
        } else if isJumbo {
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                Text(message.body)
                    .font(.system(size: 52))
                    .padding(.vertical, 2)
                metadataRow(onBubble: false)
            }
        } else if let locPayload = LocationPayload.decode(message.body) {
            // Map only, with live status, time and delivery underneath.
            LocationBubble(payload: locPayload, isOutgoing: message.isOutgoing,
                           footer: AnyView(metadataRow(onBubble: false)))
        } else if message.body.hasPrefix(notepadPrefix) {
            bubbleChrome(
                HStack(alignment: .lastTextBaseline, spacing: 7) {
                    NotepadUpdateBubble(isOutgoing: message.isOutgoing)
                    metadataRow
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            )
        } else if message.body.hasPrefix("__poll__:") {
            VStack(alignment: .trailing, spacing: -4) {
                PollBubble(
                    message: message, service: service,
                    conversationId: conversationId, isOutgoing: message.isOutgoing
                )
                metadataRow(onBubble: false)
                    .padding([.trailing, .bottom], 12)
            }
            .frame(minWidth: 240)
            .modifier(NeutralCard())
        } else if isViewOnce {
            ViewOnceOverlay(
                message: message, service: service,
                conversationId: conversationId, isOutgoing: message.isOutgoing
            )
        } else if message.body == MessagingService.stickerMarker, message.attachments.count == 1,
                  let sticker = message.attachments.first, sticker.isImage {
            // Sticker: no bubble, time and status underneath.
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                AttachmentImageView(
                    attachment: sticker, service: service, conversationId: conversationId,
                    requiresBiometric: mediaRequiresBiometric, senderName: avatarName, isSticker: true,
                    isOutgoing: message.isOutgoing
                )
                metadataRow(onBubble: false)
                    .padding(.horizontal, 4)
            }
        } else if !message.attachments.isEmpty && message.body.isEmpty && message.replyTo == nil
                    && message.attachments.allSatisfy(\.isImage) {
            // Image-only: no bubble fill, time and status underneath.
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                attachmentStack
                metadataRow(onBubble: false)
                    .padding(.horizontal, 4)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if let quote = message.replyTo {
                    let authorName = quote.author == service.credentials.accountId
                        ? "You"
                        : service.displayName(forAccount: quote.author)
                    QuotedContentView(quote: quote, isOutgoing: message.isOutgoing, authorName: authorName)
                        .contentShape(.rect)
                        .onTapGesture {
                            NotificationCenter.default.post(name: .relayJumpToQuote, object: quote)
                        }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Shows the original message")
                }
                attachmentStack
                let displayBody = message.body.hasPrefix("~once~")
                    ? String(message.body.dropFirst("~once~".count)) : message.body
                if let url = displayBody.firstURL, let relayLink = RelayLink(url),
                   displayBody.trimmingCharacters(in: .whitespacesAndNewlines) == displayBody.firstURLText,
                   message.isOutgoing || !inRequestChat {
                    // Just a Relay link: the card alone, no raw URL above it.
                    RelayLinkCard(link: relayLink, url: url,
                                  preview: service.linkPreview(forMessage: message.id),
                                  isOutgoing: message.isOutgoing, service: service, standalone: true)
                        .padding(.top, 4)
                    metadataRow
                        .frame(maxWidth: 240, alignment: .trailing)
                        .padding(.top, -4)
                } else if !displayBody.isEmpty {
                    if let editVersions {
                        if editVersions.isEmpty {
                            Text("Earlier versions aren't on this device.")
                                .font(.caption)
                                .opacity(0.55)
                        }
                        ForEach(Array(editVersions.enumerated()), id: \.offset) { _, version in
                            bodyText(version)
                                .fixedSize(horizontal: false, vertical: true)
                                .opacity(0.5)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    if effectiveStatus == .failed {
                        // The long "Not Delivered · Tap to Retry" beside the
                        // text would squeeze it to a word per line.
                        VStack(alignment: .trailing, spacing: 4) {
                            bodyText(displayBody)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            metadataRow
                        }
                    } else {
                        if dynamicTypeSize.isAccessibilitySize {
                            // Large text gets the whole width; the time goes under it.
                            VStack(alignment: .trailing, spacing: 4) {
                                bodyText(displayBody)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                metadataRow
                            }
                        } else {
                            HStack(alignment: .lastTextBaseline, spacing: 7) {
                                bodyText(displayBody)
                                    .fixedSize(horizontal: false, vertical: true)
                                metadataRow
                            }
                        }
                    }
                    if message.editedAt != nil {
                        Button(action: onToggleEditHistory) {
                            HStack(spacing: 3) {
                                Image(systemName: "pencil")
                                Text("Edited")
                            }
                            .font(.caption2)
                            .foregroundStyle(message.isOutgoing ? .white.opacity(0.75) : .secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Edited")
                        .accessibilityHint(editVersions == nil ? "Shows earlier versions" : "Hides earlier versions")
                    }
                    if let url = displayBody.firstURL, message.isOutgoing || !inRequestChat {
                        if let relayLink = RelayLink(url) {
                            RelayLinkCard(link: relayLink, url: url,
                                          preview: service.linkPreview(forMessage: message.id),
                                          isOutgoing: message.isOutgoing, service: service)
                        } else {
                            LinkPreviewView(url: url, isOutgoing: message.isOutgoing,
                                            preview: service.linkPreview(forMessage: message.id))
                        }
                    }
                } else if !isLoneVoiceNote {
                    metadataRow
                        .padding(.top, -2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .modifier(BubbleChrome(isOutgoing: message.isOutgoing, cornerRadii: cornerRadii, appearance: appearance))
        }
    }

    /// The standard bubble fill, border and shadow around `content`.
    private func bubbleChrome<Content: View>(_ content: Content) -> some View {
        content.modifier(BubbleChrome(isOutgoing: message.isOutgoing, cornerRadii: cornerRadii, appearance: appearance))
    }

    @ViewBuilder
    private var attachmentStack: some View {
        ForEach(message.attachments) { attachment in
            if attachment.isImage {
                AttachmentImageView(
                    attachment: attachment,
                    service: service,
                    conversationId: conversationId,
                    requiresBiometric: mediaRequiresBiometric,
                    senderName: avatarName,
                    isOutgoing: message.isOutgoing
                )
            } else if attachment.isAudio {
                VoiceNoteBubble(
                    attachment: attachment, service: service,
                    conversationId: conversationId, isOutgoing: message.isOutgoing,
                    requiresBiometric: mediaRequiresBiometric,
                    messageTimestamp: message.timestamp,
                    senderTitle: message.isOutgoing ? "You" : avatarName
                ) {
                    if isLoneVoiceNote { metadataRow }
                }
            } else if attachment.isVideo {
                VideoPlayerBubble(
                    attachment: attachment, service: service,
                    conversationId: conversationId, isOutgoing: message.isOutgoing,
                    requiresBiometric: mediaRequiresBiometric
                )
            } else {
                FileAttachmentBubble(
                    attachment: attachment, service: service,
                    conversationId: conversationId, isOutgoing: message.isOutgoing,
                    requiresBiometric: mediaRequiresBiometric,
                    senderName: message.isOutgoing ? "You" : avatarName
                )
            }
        }
    }

    private var reactionChips: [ReactionChip] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        var mine: Set<String> = []
        for reaction in message.reactions {
            if counts[reaction.emoji] == nil { order.append(reaction.emoji) }
            counts[reaction.emoji, default: 0] += 1
            if reaction.isOutgoing { mine.insert(reaction.emoji) }
        }
        return order.map { ReactionChip(emoji: $0, count: counts[$0] ?? 0, mine: mine.contains($0)) }
    }

    private var cornerRadii: RectangleCornerRadii {
        let radius = DS.Radius.bubble
        return RectangleCornerRadii(
            topLeading: radius,
            bottomLeading: radius,
            bottomTrailing: radius,
            topTrailing: radius
        )
    }

    /// Parsed-body cache keyed by (username, text). Markdown parsing is expensive
    /// and `body` re-runs on every scroll. Bounded; main-actor only.
    private static var formattedBodyCache: [String: AttributedString] = [:]

    /// A message's text, with spoilers hidden until tapped.
    private func bodyText(_ text: String) -> some View {
        let hasSpoilers = Spoilers.contains(text)
        return Text(formattedBody(text))
            .tint(message.isOutgoing ? .white : .accentColor)
            .accessibilityLabel(hasSpoilers && !spoilersRevealed
                                ? Spoilers.redact(text).replacingOccurrences(of: Spoilers.placeholder, with: "spoiler")
                                : Spoilers.reveal(text))
            .accessibilityAction(named: "Reveal Spoiler") {
                if hasSpoilers { onRevealSpoilers() }
            }
    }

    static let spoilerScheme = "relay-spoiler"

    /// Hidden spoiler text: a run of dot patterns as long as the text, as a
    /// link so tapping it reveals the message's spoilers.
    private static func spoilerNoise(length: Int) -> AttributedString {
        let dots = Array("⣿⣷⣯⣟⡿⢿⣻⣽⣾⣶")
        // Braille cells are wider than most letters.
        let count = max(Int((Double(length) * 0.6).rounded()), 3)
        var noise = AttributedString(String((0..<count).map { dots[($0 * 7 + 3) % dots.count] }))
        noise.link = URL(string: "\(spoilerScheme):reveal")
        return noise
    }

    /// Replaces each ||spoiler|| with its text (revealed) or noise.
    private static func applySpoilers(_ input: AttributedString, revealed: Bool, onBubble: Bool) -> AttributedString {
        var result = input
        while let match = String(result.characters).firstMatch(of: Spoilers.regex),
              let lower = AttributedString.Index(match.range.lowerBound, within: result),
              let upper = AttributedString.Index(match.range.upperBound, within: result) {
            let innerLower = result.characters.index(lower, offsetBy: 2)
            let innerUpper = result.characters.index(upper, offsetBy: -2)
            var inner = AttributedString(result[innerLower..<innerUpper])
            if revealed {
                inner.backgroundColor = onBubble ? Color.white.opacity(0.18) : Color.primary.opacity(0.08)
            } else {
                inner = spoilerNoise(length: inner.characters.count)
            }
            result.replaceSubrange(lower..<upper, with: inner)
        }
        return result
    }

    private func formattedBody(_ text: String) -> AttributedString {
        let spoilerState = Spoilers.contains(text) ? (spoilersRevealed ? "\u{2}r" : "\u{2}h") : ""
        let cacheKey = "\(service.username ?? "")\u{1}\(text)\(spoilerState)"
        if let cached = Self.formattedBodyCache[cacheKey] { return cached }

        var base = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
        if let username = service.username {
            let target = "@\(username)"
            let raw = String(base.characters)
            var searchIdx = raw.startIndex
            // Whole mentions only: "@test2" must not light up inside "@test2ax"
            // or "me@test2".
            func isNameChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
            while let found = raw.range(of: target, options: .caseInsensitive, range: searchIdx..<raw.endIndex) {
                let endsWord = found.upperBound == raw.endIndex || !isNameChar(raw[found.upperBound])
                let startsWord = found.lowerBound == raw.startIndex || !isNameChar(raw[raw.index(before: found.lowerBound)])
                if endsWord, startsWord,
                   let lower = AttributedString.Index(found.lowerBound, within: base),
                   let upper = AttributedString.Index(found.upperBound, within: base) {
                    base[lower..<upper].foregroundColor = .orange
                }
                searchIdx = found.upperBound
            }
        }
        // Underlined, so links read as links in white on a coloured bubble.
        for run in base.runs where run.link != nil {
            base[run.range].underlineStyle = .single
        }
        if !spoilerState.isEmpty {
            base = Self.applySpoilers(base, revealed: spoilersRevealed, onBubble: message.isOutgoing)
        }
        if Self.formattedBodyCache.count > 800 { Self.formattedBodyCache.removeAll() }
        Self.formattedBodyCache[cacheKey] = base
        return base
    }

    private var timeLabel: String {
        Date(timeIntervalSince1970: Double(message.timestamp) / 1000)
            .formatted(date: .omitted, time: .shortened)
    }

    private var metadataRow: some View { metadataRow(onBubble: true) }

    /// A voice message on its own: its time and status sit on the
    /// player's duration line instead of a line of their own.
    private var isLoneVoiceNote: Bool {
        message.body.isEmpty && message.attachments.count == 1 && message.attachments[0].isAudio
            && effectiveStatus != .failed
    }

    /// `onBubble` is false when drawn on the chat background (image-only and
    /// emoji-only messages), where the outgoing bubble's white text would vanish.
    private func metadataRow(onBubble: Bool) -> some View {
        HStack(spacing: 3) {
            if message.isStarred {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
            }
            Text(timeLabel)
            if message.isOutgoing {
                statusView(onBubble: onBubble)
            }
        }
        // A text style (not a fixed point size) so it follows Dynamic Type.
        .font(.caption2)
        .foregroundStyle(message.isOutgoing && onBubble ? .white.opacity(0.62) : .secondary)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .fixedSize()
        .contentShape(.rect)
    }

    /// In a group, the status aggregates every member's receipts.
    private var effectiveStatus: MessageStatus {
        isGroup ? service.groupAggregateStatus(for: message, in: conversationId) : message.status
    }

    @ViewBuilder
    private func statusView(onBubble: Bool) -> some View {
        switch effectiveStatus {
        case .sending:
            Image(systemName: "clock")
        case .sent:
            Image(systemName: "checkmark")
        case .delivered:
            Image(systemName: "checkmark.circle")
        case .read:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(message.isOutgoing && onBubble ? Color.white.opacity(0.72) : Color.accentColor)
        case .failed:
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.circle.fill")
                Text("Not Delivered · Tap to Retry")
            }
            .foregroundStyle(.red)
            .contentShape(.rect)
            .onTapGesture { Task { await service.retrySend(message) } }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Not delivered. Retry")
        case .received:
            EmptyView()
        }
    }
}

// MARK: - Long-press menu

private struct MessageActionSpec: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    var role: ButtonRole? = nil
    let action: () -> Void
}

private struct NativeMenuBubble: UIViewRepresentable {
    let bubble: AnyView
    let isOutgoing: Bool
    let reactions: [String]
    let currentReaction: String?
    let actions: [MessageActionSpec]
    let onReact: (String) -> Void
    let onDoubleTap: () -> Void
    let onReply: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let coord = context.coordinator
        let container = UIView()
        container.backgroundColor = .clear

        let host = coord.host
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: container.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Our own long-press menu (MessageMenuOverlay), not UIContextMenu: the
        // system moves the message to fit its menu, which left a separately
        // placed reaction bar on top of the menu.
        let press = UILongPressGestureRecognizer(target: coord, action: #selector(Coordinator.handleLongPress(_:)))
        press.minimumPressDuration = 0.35
        press.delegate = coord
        host.view.addGestureRecognizer(press)

        // Right-click (Mac, iPad with a trackpad or mouse) opens the same menu.
        let rightClick = UITapGestureRecognizer(target: coord, action: #selector(Coordinator.handleSecondaryClick(_:)))
        rightClick.buttonMaskRequired = .secondary
        rightClick.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        host.view.addGestureRecognizer(rightClick)

        let double = UITapGestureRecognizer(target: coord, action: #selector(Coordinator.handleDoubleTap))
        double.numberOfTapsRequired = 2
        host.view.addGestureRecognizer(double)

        let pan = UIPanGestureRecognizer(target: coord, action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = coord
        host.view.addGestureRecognizer(pan)

        coord.sourceView = host.view
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.host.rootView = bubble
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        return context.coordinator.host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: NativeMenuBubble
        let host: UIHostingController<AnyView>
        weak var sourceView: UIView?

        init(_ parent: NativeMenuBubble) {
            self.parent = parent
            self.host = UIHostingController(rootView: parent.bubble)
            self.host.view.backgroundColor = .clear
            super.init()
        }

        @objc func handleDoubleTap() { parent.onDoubleTap() }

        @objc func handleSecondaryClick(_ g: UITapGestureRecognizer) {
            guard g.state == .ended else { return }
            showMenu()
        }

        @objc func handleLongPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            showMenu()
        }

        private func showMenu() {
            guard let source = sourceView, !MessageMenuOverlay.isShowing else { return }
            MessageMenuOverlay.show(
                from: source, isOutgoing: parent.isOutgoing,
                reactions: parent.reactions, current: parent.currentReaction,
                actions: parent.actions, onReact: parent.onReact
            )
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let v = sourceView else { return }
            let tx = g.translation(in: v).x
            switch g.state {
            case .changed:
                v.transform = CGAffineTransform(translationX: max(-70, min(70, tx * 0.5)), y: 0)
            case .ended, .cancelled, .failed:
                if abs(tx) > 60 { parent.onReply() }
                UIView.animate(withDuration: 0.25) { v.transform = .identity }
            default:
                break
            }
        }

        // Claim the pan only for mostly-horizontal drags so vertical scrolling wins.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer, let v = sourceView else { return true }
            let t = pan.translation(in: v)
            return abs(t.x) > abs(t.y)
        }
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // The long press mustn't fire mid-scroll or mid-swipe.
            !(g is UILongPressGestureRecognizer)
        }
    }
}

/// The long-press menu: the chat dims, the message lifts, the reaction bar
/// sits directly above it and the actions directly below (or above, when
/// there's no room), all kept on screen. Laid out in one place so the pieces
/// can never overlap.
@MainActor
private enum MessageMenuOverlay {
    private static var window: UIWindow?
    private static weak var source: UIView?
    static var isShowing: Bool { window != nil }

    static func show(from source: UIView, isOutgoing: Bool, reactions: [String], current: String?,
                     actions: [MessageActionSpec], onReact: @escaping (String) -> Void) {
        guard window == nil, let scene = source.window?.windowScene,
              let snapshot = source.snapshotView(afterScreenUpdates: false) else { return }
        self.source = source
        let bounds = scene.screen.bounds
        let insets = source.window?.safeAreaInsets ?? .zero
        let srcFrame = source.convert(source.bounds, to: nil)

        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        w.backgroundColor = .clear
        let root = DismissibleOverlayController()
        root.view.backgroundColor = .clear
        root.view.accessibilityViewIsModal = true
        w.rootViewController = root

        let dim = UIVisualEffectView(effect: nil)
        dim.isAccessibilityElement = true
        dim.accessibilityLabel = "Close menu"
        dim.accessibilityTraits = .button
        dim.frame = bounds
        dim.isUserInteractionEnabled = true
        dim.addGestureRecognizer(UITapGestureRecognizer(target: OverlayTarget.shared, action: #selector(OverlayTarget.dismissTap)))
        root.view.addSubview(dim)

        let bar = UIHostingController(rootView: ReactionBarView(reactions: reactions, current: current) { emoji in
            onReact(emoji)
            dismiss()
        })
        bar.view.backgroundColor = .clear
        let barSize = bar.sizeThatFits(in: CGSize(width: bounds.width - 24, height: 80))

        let menu = UIHostingController(rootView: MessageActionMenu(actions: actions) { action in
            dismiss { action.action() }
        })
        menu.view.backgroundColor = .clear
        let menuSize = menu.sizeThatFits(in: CGSize(width: 250, height: bounds.height))

        // Vertical layout: bar, gap, message, gap, menu. A message taller than
        // the room left shows its top part.
        let gap: CGFloat = 8
        let top = insets.top + 8
        let bottom = bounds.height - insets.bottom - 8
        let room = bottom - top - barSize.height - menuSize.height - gap * 2
        let bubbleHeight = min(srcFrame.height, max(80, room))
        var bubbleY = srcFrame.minY
        var menuBelow = true
        if bubbleY - gap - barSize.height < top { bubbleY = top + barSize.height + gap }
        if bubbleY + bubbleHeight + gap + menuSize.height > bottom {
            // Not enough room below: try the menu above the bar instead.
            let aboveTop = srcFrame.minY - gap - barSize.height - gap - menuSize.height
            if aboveTop >= top, srcFrame.minY + bubbleHeight <= bottom {
                menuBelow = false
                bubbleY = srcFrame.minY
            } else {
                bubbleY = bottom - menuSize.height - gap - bubbleHeight
            }
        }
        bubbleY = max(bubbleY, top + barSize.height + gap + (menuBelow ? 0 : menuSize.height + gap))

        let bubbleFrame = CGRect(x: srcFrame.minX, y: bubbleY, width: srcFrame.width, height: bubbleHeight)
        func alignedX(_ width: CGFloat) -> CGFloat {
            let x = isOutgoing ? bubbleFrame.maxX - width : bubbleFrame.minX
            return max(12, min(x, bounds.width - width - 12))
        }
        let barFrame = CGRect(x: alignedX(barSize.width), y: bubbleFrame.minY - gap - barSize.height,
                              width: barSize.width, height: barSize.height)
        let menuFrame = CGRect(
            x: alignedX(menuSize.width),
            y: menuBelow ? bubbleFrame.maxY + gap : barFrame.minY - gap - menuSize.height,
            width: menuSize.width, height: menuSize.height)

        let clip = UIView(frame: srcFrame)
        clip.clipsToBounds = true
        snapshot.frame = CGRect(origin: .zero, size: srcFrame.size)
        clip.addSubview(snapshot)
        root.view.addSubview(clip)

        root.addChild(bar)
        bar.view.frame = barFrame
        root.view.addSubview(bar.view)
        root.addChild(menu)
        menu.view.frame = menuFrame
        root.view.addSubview(menu.view)

        for v in [bar.view!, menu.view!] {
            v.alpha = 0
            v.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
        }
        w.isHidden = false
        window = w
        source.alpha = 0

        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0.4) {
            dim.effect = UIBlurEffect(style: .systemUltraThinMaterial)
            clip.frame = bubbleFrame
            clip.transform = CGAffineTransform(scaleX: 1.02, y: 1.02)
            for v in [bar.view!, menu.view!] {
                v.alpha = 1
                v.transform = .identity
            }
        }
    }

    static func dismiss(then completion: (() -> Void)? = nil) {
        guard let w = window else { completion?(); return }
        window = nil
        UIView.animate(withDuration: 0.18, animations: {
            w.alpha = 0
        }, completion: { _ in
            w.isHidden = true
            source?.alpha = 1
            completion?()
        })
    }

    /// VoiceOver's two-finger scrub and Escape on a keyboard close the menu.
    final class DismissibleOverlayController: UIViewController {
        override func accessibilityPerformEscape() -> Bool {
            MessageMenuOverlay.dismiss()
            return true
        }
        override var keyCommands: [UIKeyCommand]? {
            [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape))]
        }
        override var canBecomeFirstResponder: Bool { true }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            becomeFirstResponder()
        }
        @objc private func escape() { MessageMenuOverlay.dismiss() }
    }

    /// Target for the background tap.
    final class OverlayTarget: NSObject {
        static let shared = OverlayTarget()
        @objc func dismissTap() { MessageMenuOverlay.dismiss() }
    }
}

private struct MessageActionMenu: View {
    let actions: [MessageActionSpec]
    let onSelect: (MessageActionSpec) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(actions) { action in
                Button { onSelect(action) } label: {
                    HStack(spacing: 12) {
                        Text(action.label)
                        Spacer(minLength: 16)
                        Image(systemName: action.icon)
                            .frame(width: 22)
                    }
                    .font(.body)
                    .foregroundStyle(action.role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                    .padding(.horizontal, 14)
                    .frame(height: 42)
                    .contentShape(.rect)
                }
                .buttonStyle(MenuRowStyle())
            }
        }
        .padding(6)
        .frame(width: 250)
        .glassCompat(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

/// Rows highlight as a rounded pill inside the glass, with no dividers.
private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? Color.primary.opacity(0.1) : .clear,
                in: .rect(cornerRadius: 16, style: .continuous)
            )
    }
}

private struct ReactionBarView: View {
    let reactions: [String]
    let current: String?
    let onReact: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(reactions, id: \.self) { emoji in
                Button { onReact(emoji) } label: {
                    Text(emoji)
                        .font(.system(size: 30))
                        .frame(width: 44, height: 44)
                        .background(
                            current == emoji
                                ? AnyShapeStyle(Color.accentColor.opacity(0.28))
                                : AnyShapeStyle(Color.clear),
                            in: .circle
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassCompat(in: .capsule)
        .shadow(color: .black.opacity(0.2), radius: 14, y: 8)
    }
}

// MARK: - Reactions

struct ReactionChip: Identifiable {
    let emoji: String
    let count: Int
    let mine: Bool
    var id: String { emoji }
}

private struct ReactionBadges: View {
    let chips: [ReactionChip]
    let onTap: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(chips) { chip in
                Button { onTap(chip.emoji) } label: {
                    HStack(spacing: 2) {
                        Text(chip.emoji).font(.caption)
                        if chip.count > 1 {
                            Text("\(chip.count)")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .glassCompat(in: .capsule)
                    .overlay {
                        Capsule().strokeBorder(
                            chip.mine ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.systemBackground).opacity(0.75)),
                            lineWidth: chip.mine ? 1.5 : 1
                        )
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reaction \(chip.emoji), \(chip.count)")
            }
        }
        .contentShape(.rect)
    }
}

private struct ReactionEmojiID: Identifiable {
    let emoji: String
    var id: String { emoji }
}

private struct ReactionAttributionSheet: View {
    let emoji: String
    let reactions: [MessageReaction]
    let service: MessagingService

    var body: some View {
        NavigationStack {
            List(reactions, id: \.author) { reaction in
                HStack(spacing: 12) {
                    Text(reaction.emoji).font(.title2)
                    Text(service.displayName(forAccount: reaction.author))
                        .font(.body)
                }
            }
            .navigationTitle("Reacted with \(emoji)")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Quote rendering

private struct QuotedContentView: View {
    let quote: QuotedMessage
    let isOutgoing: Bool
    let authorName: String

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(isOutgoing ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(authorName)
                    .font(.caption2.weight(.semibold))
                    .opacity(isOutgoing ? 1 : 0.8)
                Text(quote.text.isEmpty ? "Message"
                     : quote.text == MessagingService.stickerMarker ? "Sticker" : Spoilers.redact(quote.text))
                    .font(.footnote)
                    .lineLimit(2)
                    .opacity(isOutgoing ? 0.8 : 0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(
            (isOutgoing ? Color.white.opacity(0.18) : Color.primary.opacity(0.06)),
            in: .rect(cornerRadius: 8)
        )
    }
}

private struct EditPreviewBar: View {
    let message: StoredMessage
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(.tint)
                .frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Label("Editing", systemImage: "pencil")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(message.body)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .accessibilityLabel("Cancel")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .glassCompat(in: .rect(cornerRadius: 14))
    }
}

private struct FormatButton: View {
    let symbol: String
    let tip: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(.label))
                .frame(width: 36, height: 30)
                .background(Color(.secondarySystemFill), in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tip)
        .help(tip)
    }
}

private struct ReplyPreviewBar: View {
    let message: StoredMessage
    let isOwnAuthor: Bool
    let peerName: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(.tint)
                .frame(width: 3, height: 34)
            if let symbol = attachmentSymbol {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 7))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Reply to \(isOwnAuthor ? "You" : peerName)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(replySnippet)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .accessibilityLabel("Cancel")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .glassCompat(in: .rect(cornerRadius: 14))
    }

    private var attachmentSymbol: String? {
        guard let attachment = message.attachments.first else { return nil }
        if attachment.isImage { return "photo" }
        if attachment.isVideo { return "video.fill" }
        if attachment.isAudio { return "waveform" }
        return "doc.fill"
    }

    private var replySnippet: String {
        if !message.body.isEmpty { return message.body }
        guard let attachment = message.attachments.first else { return "Message" }
        if attachment.isImage { return "Photo" }
        if attachment.isVideo { return "Video" }
        if attachment.isAudio { return "Voice message" }
        return attachment.filename ?? "File"
    }
}

// MARK: - Attachments

/// Downloads an image attachment on first view and decrypts it in memory.
/// Plaintext never touches disk.
private struct AttachmentImageView: View {
    let attachment: StoredAttachment
    let service: MessagingService
    let conversationId: String
    let requiresBiometric: Bool
    var senderName: String = ""
    /// Stickers: smaller, whole image visible, no rounded crop.
    var isSticker = false
    var isOutgoing = false

    @State private var image: UIImage?
    @Environment(\.relayIsMessageRequest) private var inRequest
    /// A request's media isn't downloaded or shown until it's accepted.
    private var hiddenForRequest: Bool { inRequest && !isOutgoing }
    @State private var isSensitive = false
    @State private var sensitiveRevealed = false
    @State private var gifData: Data?
    @State private var failed = false
    @State private var preview: PreviewItem?
    @State private var previewFileURL: URL?
    @State private var isUnlocked = false

    private var isGIF: Bool { attachment.contentType == "image/gif" }

    private var canDragOut: Bool {
        image != nil && !coversSensitive
            && !hiddenForRequest && !(requiresBiometric && !isUnlocked)
    }

    private var height: CGFloat {
        guard attachment.width > 0, attachment.height > 0 else { return 240 }
        let aspect = CGFloat(attachment.width) / CGFloat(attachment.height)
        return max(120, min(320, 240 / aspect))
    }

    var body: some View {
        Group {
            if isGIF, let data = gifData {
                AnimatedGIFView(data: data)
                    .blur(radius: (requiresBiometric && !isUnlocked) ? 18 : 0)
                    .overlay {
                        if requiresBiometric && !isUnlocked {
                            AttachmentPrivacyOverlay(label: "Unlock photo")
                        }
                    }
                    .contentShape(.rect)
                    .onTapGesture {
                        if requiresBiometric && !isUnlocked {
                            Task { await unlock() }
                        } else {
                            Task { await openPreview() }
                        }
                    }
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: isSticker ? .fit : .fill)
                    .blur(radius: (requiresBiometric && !isUnlocked) ? 18 : 0)
                    .overlay {
                        if requiresBiometric && !isUnlocked {
                            AttachmentPrivacyOverlay(label: "Unlock photo")
                        }
                    }
                    .contentShape(.rect)
                    .onTapGesture {
                        if requiresBiometric && !isUnlocked {
                            Task { await unlock() }
                        } else {
                            Task { await openPreview() }
                        }
                    }
            } else {
                ZStack {
                    Rectangle().fill(.fill.tertiary)
                    if hiddenForRequest {
                        VStack(spacing: 6) {
                            Image(systemName: "eye.slash")
                            Text("Accept to view").font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)
                    } else if failed {
                        VStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("Tap to retry").font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
                .contentShape(.rect)
                .onTapGesture { if failed { Task { await load() } } }
            }
        }
        .blur(radius: coversSensitive ? 40 : 0)
        .frame(width: isSticker ? 150 : 240, height: isSticker ? 150 : height)
        .overlay {
            if coversSensitive {
                SensitiveMediaCover(restricted: SensitiveContent.isRestricted, compact: isSticker) {
                    sensitiveRevealed = true
                }
            }
        }
        .clipShape(.rect(cornerRadius: isSticker ? 0 : 16))
        // iPad: drag the photo out to another app (with a pointer; a touch
        // long-press opens the message menu instead).
        .modifier(DragOutImage(image: canDragOut ? image : nil))
        .accessibilityElement(children: coversSensitive ? .contain : .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(coversSensitive ? [] : [.isButton, .isImage])
        .accessibilityHint(coversSensitive ? "" : (requiresBiometric && !isUnlocked ? "Unlocks the photo" : "Opens the photo"))
        .task(id: "\(attachment.id)-\(hiddenForRequest)") { await load() }
        .fullScreenCover(item: $preview, onDismiss: cleanUpPreviewFile) { item in
            QuickLookPreview(url: item.url, title: senderName)
                .ignoresSafeArea()
        }
        .onDisappear { if preview == nil { cleanUpPreviewFile() } }
    }

    /// Deletes the decrypted temp file once the preview has closed.
    private func cleanUpPreviewFile() {
        TempMediaFiles.remove(previewFileURL)
        previewFileURL = nil
    }

    private func load() async {
        failed = false
        guard !hiddenForRequest else { return }
        if !attachment.isDownloaded {
            await service.downloadAttachment(attachment, in: conversationId)
        }
        guard let data = service.attachmentPlaintext(attachment) else {
            failed = true
            return
        }
        if !isOutgoing {
            isSensitive = await SensitiveContent.isSensitive(imageData: data, cacheKey: attachment.id)
        }
        if isGIF {
            gifData = data
        } else if let ui = SafeImage.image(from: data, maxPixelSize: SafeImage.inlinePixelSize) {
            image = ui
        } else {
            failed = true
        }
    }

    private var accessibilityDescription: String {
        let kind = isSticker ? "Sticker" : (isGIF ? "GIF" : "Photo")
        if coversSensitive { return "\(kind) hidden because it may be sensitive" }
        if failed { return "\(kind) failed to load. Double-tap to retry" }
        return senderName.isEmpty ? kind : "\(kind) from \(senderName)"
    }

    private var coversSensitive: Bool {
        isSensitive && (SensitiveContent.isRestricted || !sensitiveRevealed)
    }

    private func unlock() async {
        guard await BiometricGate.authenticate(reason: "Unlock this photo in Relay.") else { return }
        isUnlocked = true
    }

    private func openPreview() async {
        if !attachment.isDownloaded {
            await service.downloadAttachment(attachment, in: conversationId)
        }
        guard let data = service.attachmentPlaintext(attachment) else { return }
        let ext = UTType(mimeType: attachment.contentType)?.preferredFilenameExtension ?? "jpg"
        do {
            // Random filename + complete protection; deleted when the preview closes.
            let url = try TempMediaFiles.write(data, originalName: attachment.filename, fallbackExtension: ext)
            TempMediaFiles.remove(previewFileURL)
            previewFileURL = url
            preview = PreviewItem(url: url)
        } catch {
            Logger(subsystem: "app.relaymsg", category: "chat")
                .error("openPreview: temp write failed: \(PrivacyRedactor.error(error))")
        }
    }
}

/// Preview of an unsent attachment above the composer.
private struct PendingAttachmentBar: View {
    let attachment: MessagingService.PendingAttachment
    let onPreview: () -> Void
    let onCancel: () -> Void

    private var isImage: Bool { attachment.contentType.hasPrefix("image/") }
    private var isVideo: Bool { attachment.contentType.hasPrefix("video/") }

    var body: some View {
        HStack(spacing: 10) {
            if isImage, let ui = DecodedImageCache.image(for: attachment.data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(.rect(cornerRadius: 8))
                Text(attachment.contentType == "image/gif" ? "GIF" : "Photo")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if isVideo {
                Image(systemName: "video.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                Text(attachment.filename ?? "Video")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Image(systemName: "doc.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                Text(attachment.filename ?? "File")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .accessibilityLabel("Cancel")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .glassCompat(in: .rect(cornerRadius: 14))
        .contentShape(.rect(cornerRadius: 12))
        .onTapGesture { onPreview() }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Previews the attachment")
    }
}

private struct PendingAttachmentPreviewSheet: View {
    let attachments: [MessagingService.PendingAttachment]
    @Binding var caption: String
    @Binding var viewOnce: Bool
    let onRemove: (Int) -> Void
    let onSend: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var allowsViewOnce: Bool {
        attachments.allSatisfy { $0.contentType.hasPrefix("image/") }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                            previewCard(for: attachment, index: index)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }

                TextField("Add a caption", text: $caption, axis: .vertical).incognitoKeyboard()
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 16)

                if allowsViewOnce {
                    Toggle(isOn: $viewOnce) {
                        Label("View once", systemImage: viewOnce ? "eye.fill" : "eye.slash")
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 10)
            .navigationTitle(attachments.count == 1 ? "Preview" : "\(attachments.count) Items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onSend()
                        dismiss()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                    }
                    .accessibilityLabel("Send")
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(attachments.isEmpty && caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func previewCard(for attachment: MessagingService.PendingAttachment, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            if attachment.contentType.hasPrefix("image/"), let image = DecodedImageCache.image(for: attachment.data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                VStack(spacing: 10) {
                    Image(systemName: attachment.contentType.hasPrefix("video/") ? "video.fill" : "doc.fill")
                        .font(.system(size: 32, weight: .semibold))
                    Text(attachment.filename ?? (attachment.contentType.hasPrefix("video/") ? "Video" : "File"))
                        .font(.footnote)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.fill.tertiary)
            }
            Button { onRemove(index) } label: {
                Image(systemName: "xmark.circle.fill")
                    .accessibilityLabel("Remove attachment")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .padding(8)
        }
        .frame(width: 220, height: 260)
        .clipShape(.rect(cornerRadius: 18))
    }
}

// MARK: - System messages and typing indicator

// Bodies prefixed with "call:" get a phone symbol; others render as plain caption text.
private struct SystemMessageView: View {
    let rawBody: String

    private var isCallMessage: Bool { rawBody.hasPrefix("call:") }
    private var displayText: String {
        isCallMessage ? String(rawBody.dropFirst("call:".count)) : rawBody
    }
    private var callIcon: String {
        let t = displayText.lowercased()
        if t.hasPrefix("missed") { return "phone.arrow.down.left.fill" }
        if t.hasPrefix("outgoing") { return "phone.arrow.up.right.fill" }
        return "phone.fill"
    }

    @Environment(ChatAppearance.self) private var appearance

    var body: some View {
        Group {
            if isCallMessage {
                HStack(spacing: 4) {
                    Image(systemName: callIcon)
                    Text(displayText)
                }
            } else {
                Text(displayText)
                    .multilineTextAlignment(.center)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        // A pill, frosted over a photo wallpaper so it stays readable.
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            appearance.wallpaper == .photo && appearance.hasWallpaper
                ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.fill.quaternary),
            in: .capsule
        )
        .padding(.horizontal, 40)
        .accessibilityElement(children: .combine)
    }
}

private struct TypingIndicatorView: View {
    let peerName: String
    var imageData: Data? = nil
    /// Groups: who is typing, shown above the dots.
    var label: String? = nil
    @State private var phase = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            AvatarView(name: peerName, size: 28, imageData: imageData)
            VStack(alignment: .leading, spacing: 3) {
            if let label {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                    .modifier(PhotoWallpaperLabel())
            }
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .frame(width: 7, height: 7)
                        .foregroundStyle(.secondary)
                        .opacity(phase == index ? 1 : 0.35)
                        .offset(y: phase == index && !reduceMotion ? -4 : 0)
                        .animation(.spring(duration: 0.3, bounce: 0.5).delay(Double(index) * 0.05), value: phase)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(.fill.secondary, in: .rect(cornerRadius: DS.Radius.bubble))
            }
            Spacer(minLength: 56)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? "\(peerName) is typing")
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                phase = (phase + 1) % 3
            }
        }
    }
}




private struct ForwardPayload: Identifiable {
    let id = UUID()
    let messages: [StoredMessage]
}

private struct ForwardMessageSheet: View {
    let payload: ForwardPayload
    let service: MessagingService

    @Environment(\.dismiss) private var dismiss
    @State private var isSending = false

    private var conversations: [Conversation] {
        service.conversations.filter { !$0.archived }
    }

    var body: some View {
        NavigationStack {
            Group {
                if conversations.isEmpty {
                    ContentUnavailableView(
                        "No Conversations",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Start a conversation first.")
                    )
                } else {
                    List(conversations) { conv in
                        Button { forward(to: conv.id) } label: {
                            let convName = conv.isGroup
                                ? (conv.peerUsername ?? "Group")
                                : service.displayName(forAccount: conv.peerAccount)
                            let avatarImg = conv.isGroup
                                ? service.group(for: conv.id)?.avatarData
                                : service.peerAvatarData(forAccount: conv.peerAccount)
                            HStack(spacing: 12) {
                                AvatarView(name: convName, size: 44, imageData: avatarImg)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(convName)
                                        .font(.body.weight(.medium))
                                    if !conv.isGroup, let username = conv.peerUsername {
                                        Text("@\(username)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .disabled(isSending)
                    }
                }
            }
            .navigationTitle("Forward to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay { if isSending { ProgressView() } }
        }
    }

    private func forward(to conversationId: String) {
        guard !isSending else { return }
        isSending = true
        Task {
            for message in payload.messages {
                await service.forward(message, to: conversationId)
            }
            dismiss()
        }
    }
}

/// The contact or group page as a column beside the chat (wide windows).
private struct InfoColumn<Page: View>: ViewModifier {
    let enabled: Bool
    @Binding var isPresented: Bool
    @ViewBuilder let page: () -> Page

    func body(content: Content) -> some View {
        if enabled {
            content.inspector(isPresented: $isPresented) {
                page().inspectorColumnWidth(min: 320, ideal: 370, max: 440)
            }
        } else {
            content
        }
    }
}

private struct MessageInfoView: View {
    let message: StoredMessage
    let isOwnAuthor: Bool
    let peerName: String
    var service: MessagingService? = nil
    var conversationId: String? = nil
    var isGroup: Bool = false

    private var members: [MessagingService.MemberReceipt] {
        guard isGroup, message.isOutgoing, let service, let conversationId else { return [] }
        return service.groupReceipts(for: message, in: conversationId)
    }

    var body: some View {
        List {
            Section {
                LabeledContent("From", value: isOwnAuthor ? "You" : peerName)
                LabeledContent(message.isOutgoing ? "Sent" : "Received", value: Self.full(sentDate))
            }
            if message.isOutgoing && !isGroup, let service {
                let times = service.receiptTimes(for: message)
                Section("Status") {
                    timeRow("Delivered", systemImage: "checkmark.circle", date: times.delivered
                            ?? (message.status == .delivered || message.status == .read ? sentDate : nil),
                            known: times.delivered != nil)
                    timeRow("Read", systemImage: "checkmark.circle.fill", date: times.read
                            ?? (message.status == .read ? sentDate : nil),
                            known: times.read != nil)
                }
            }
            if !members.isEmpty {
                let read = members.filter { $0.status == .read }
                let delivered = members.filter { $0.status == .delivered }
                let pending = members.filter { $0.status == nil || $0.status == .sent }
                if !read.isEmpty {
                    Section("Read by \(read.count) of \(members.count)") {
                        ForEach(read) { memberRow($0) }
                    }
                }
                if !delivered.isEmpty {
                    Section("Delivered to") {
                        ForEach(delivered) { memberRow($0) }
                    }
                }
                if !pending.isEmpty {
                    Section("Not Delivered Yet") {
                        ForEach(pending) { memberRow($0) }
                    }
                }
            }
        }
        .navigationTitle("Message Info")
        .navigationBarTitleDisplayMode(.inline)
        .presentationDetents([.medium, .large])
    }

    private var sentDate: Date { Date(timeIntervalSince1970: Double(message.timestamp) / 1000) }

    /// `known` is false for messages read before times were recorded: the
    /// state shows, the time doesn't.
    private func timeRow(_ title: String, systemImage: String, date: Date?, known: Bool) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .foregroundStyle(date == nil ? .secondary : .primary)
            Spacer()
            Text(date == nil ? "Not yet" : (known ? Self.short(date!) : "Yes"))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func memberRow(_ member: MessagingService.MemberReceipt) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: member.name, size: 34, imageData: member.avatar)
                .accessibilityHidden(true)
            Text(member.name)
            Spacer()
            if let at = member.at {
                Text(Self.short(at)).foregroundStyle(.secondary).font(.subheadline)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private static func full(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// "4:12 PM" today, "Yesterday 4:12 PM", else the date.
    private static func short(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(date) { return "Yesterday " + date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}

// MARK: - Bubble chrome

private struct BubbleChrome: ViewModifier {
    let isOutgoing: Bool
    let cornerRadii: RectangleCornerRadii
    let appearance: ChatAppearance

    func body(content: Content) -> some View {
        content
            .background(
                isOutgoing ? AnyShapeStyle(appearance.bubbleTint) : AnyShapeStyle(incomingFill),
                in: .rect(cornerRadii: cornerRadii)
            )
            .overlay {
                if !isOutgoing {
                    UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous)
                        .strokeBorder(.primary.opacity(0.07), lineWidth: 1)
                }
            }
            .shadow(color: .black.opacity(isOutgoing ? 0.08 : 0.05), radius: 4, x: 0, y: 1)
            .foregroundStyle(isOutgoing ? .white : .primary)
    }

    /// On a wallpaper, received bubbles are lifted (white, or dark grey in
    /// dark mode) so they don't read as holes in it.
    private var incomingFill: Color {
        appearance.wallpaper == .none
            ? Color(.systemBackground).opacity(0.92)
            : Color(.tertiarySystemBackground)
    }
}

/// Date and event lines sit on the chat background as plain text; over a
/// photo wallpaper they get a frosted capsule so they stay readable.
private struct PhotoWallpaperLabel: ViewModifier {
    @Environment(ChatAppearance.self) private var appearance

    func body(content: Content) -> some View {
        if appearance.wallpaper == .photo, appearance.hasWallpaper {
            content
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: .capsule)
        } else {
            content
        }
    }
}

/// Plain card (white in light mode, black in dark) for maps and polls.
private struct NeutralCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(.systemBackground), in: .rect(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.06), radius: 5, x: 0, y: 2)
            .foregroundStyle(.primary)
    }
}

// MARK: - Location bubble

private struct LocationBubble: View {
    let payload: LocationPayload
    let isOutgoing: Bool
    let footer: AnyView

    @State private var position: MapCameraPosition

    init(payload: LocationPayload, isOutgoing: Bool, footer: AnyView) {
        self.payload = payload
        self.isOutgoing = isOutgoing
        self.footer = footer
        _position = State(initialValue: .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: payload.lat, longitude: payload.lng),
            span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
        )))
    }

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: payload.lat, longitude: payload.lng)
    }

    private func recenter() {
        withAnimation(.easeInOut(duration: 0.5)) {
            position = .region(MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
            ))
        }
    }

    /// Received locations don't load map tiles until the user asks: fetching
    /// tiles tells Apple's map servers, with our IP, where the sender is.
    @State private var mapRevealed = false
    @State private var showingFullMap = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isOutgoing || mapRevealed {
                Map(position: $position) {
                    Marker("", coordinate: coordinate)
                        .tint(.red)
                }
                .frame(height: 170)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .disabled(true)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(7)
                        .background(.regularMaterial, in: .circle)
                        .padding(6)
                }
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .onTapGesture { showingFullMap = true }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Opens the map full screen")
                // Recenter as a live share moves.
                .onChange(of: payload.lat) { _, _ in recenter() }
                .onChange(of: payload.lng) { _, _ in recenter() }
            } else {
                Button {
                    mapRevealed = true
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "map.fill")
                            .font(.title2)
                        Text("Tap to show map")
                            .font(.caption.weight(.semibold))
                        Text("Loads map tiles from Apple Maps")
                            .font(.caption2)
                            .opacity(0.7)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 170)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Shared location. Tap to show map.")
            }

            HStack(spacing: 4) {
                Image(systemName: payload.stop || payload.isExpired ? "location.slash.fill" : "location.fill")
                    .font(.caption)
                Text(payload.stop ? "Stopped sharing"
                     : payload.isExpired ? "Location expired"
                     : "Live location")
                    .font(.caption)
                Spacer(minLength: 8)
                footer
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: 240)
        .fullScreenCover(isPresented: $showingFullMap) {
            // Re-evaluated as the bubble re-renders, so a live share keeps moving.
            FullScreenLocationView(payload: payload)
        }
    }
}

/// Full-screen map for a shared or live location.
private struct FullScreenLocationView: View {
    let payload: LocationPayload
    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition
    @State private var following = true

    init(payload: LocationPayload) {
        self.payload = payload
        _position = State(initialValue: Self.region(for: payload))
    }

    private static func region(for payload: LocationPayload) -> MapCameraPosition {
        .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: payload.lat, longitude: payload.lng),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        ))
    }

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: payload.lat, longitude: payload.lng)
    }

    private var isLive: Bool { !payload.stop && !payload.isExpired }

    var body: some View {
        NavigationStack {
            Map(position: $position) {
                Marker(isLive ? "Live location" : "Shared location", coordinate: coordinate)
                    .tint(.red)
            }
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .simultaneousGesture(DragGesture().onChanged { _ in following = false })
            .onChange(of: payload.lat) { _, _ in follow() }
            .onChange(of: payload.lng) { _, _ in follow() }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(isLive ? "Live Location" : "Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        following = true
                        withAnimation { position = Self.region(for: payload) }
                    } label: {
                        Label("Center", systemImage: following ? "location.fill" : "location")
                    }
                    Spacer()
                    Button {
                        let item = MKMapItem(location: CLLocation(latitude: payload.lat, longitude: payload.lng), address: nil)
                        item.name = isLive ? "Live location" : "Shared location"
                        item.openInMaps()
                    } label: {
                        Label("Open in Maps", systemImage: "map")
                    }
                }
            }
        }
    }

    private func follow() {
        guard following else { return }
        withAnimation(.easeInOut(duration: 0.5)) { position = Self.region(for: payload) }
    }
}

// MARK: - Notepad update bubble

private struct NotepadUpdateBubble: View {
    let isOutgoing: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "note.text")
                .font(.subheadline)
            Text("Notepad updated")
                .font(.subheadline)
        }
        .foregroundStyle(isOutgoing ? .white.opacity(0.9) : .secondary)
        .padding(.vertical, 4)
    }
}

// MARK: - Summary sheet

private struct SummarySheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text.isEmpty ? "No summary available." : text)
                    .font(.body)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("AI Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Schedule picker

private struct SchedulePickerSheet: View {
    let draft: String
    @Binding var scheduledDate: Date
    let onSchedule: (Date) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(
                    "Send at",
                    selection: $scheduledDate,
                    in: Date().addingTimeInterval(60)...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.graphical)

                Section {
                    Text(draft)
                        .foregroundStyle(.secondary)
                        .font(.body)
                } header: {
                    Text("Message")
                } footer: {
                    Text("Relay sends it at this time if your phone is online. If Relay hasn't been able to run, it goes out the next time you open the app.")
                }
            }
            .navigationTitle("Schedule Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Schedule") {
                        onSchedule(scheduledDate)
                        dismiss()
                    }
                    .bold()
                }
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Location share sheet

private struct LocationShareSheet: View {
    @Binding var duration: TimeInterval
    let onStart: (TimeInterval) -> Void

    @Environment(\.dismiss) private var dismiss

    private let options: [(label: String, seconds: TimeInterval)] = [
        ("15 minutes", 900),
        ("1 hour", 3600),
        ("8 hours", 28800)
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Share for") {
                    ForEach(options, id: \.seconds) { opt in
                        Button {
                            duration = opt.seconds
                        } label: {
                            HStack {
                                Text(opt.label)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if duration == opt.seconds {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }

                Section {
                    Text("Your live location is shared end-to-end encrypted. Only the people in this conversation can see it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Share Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        onStart(duration)
                        dismiss()
                    }
                    .bold()
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - View-once overlay

private struct ViewOnceOverlay: View {
    let message: StoredMessage
    let service: MessagingService
    let conversationId: String
    let isOutgoing: Bool

    @State private var viewed = false
    @State private var image: UIImage?
    @State private var unavailable = false
    @State private var sensitiveHidden = false

    private var tint: Color { isOutgoing ? .white : .primary }
    /// The attachment row is deleted once the recipient has opened it.
    private var alreadyOpened: Bool { !isOutgoing && message.attachments.isEmpty }

    var body: some View {
        Group {
            if viewed, let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .blur(radius: sensitiveHidden ? 40 : 0)
                    .frame(maxWidth: 240)
                    .overlay {
                        if sensitiveHidden {
                            SensitiveMediaCover(restricted: SensitiveContent.isRestricted) {
                                sensitiveHidden = false
                            }
                        }
                    }
                    .clipShape(.rect(cornerRadius: 12))
            } else if isOutgoing || alreadyOpened || unavailable {
                // The sender can't open their own view-once photo (it would
                // destroy their copy); a recipient gets one look.
                label(
                    icon: alreadyOpened || unavailable ? "eye.slash" : "eye",
                    text: isOutgoing ? "View-once photo" : (unavailable ? "Photo unavailable" : "Opened")
                )
                .opacity(0.8)
            } else {
                Button { Task { await reveal() } } label: {
                    label(icon: "eye.fill", text: "View once")
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the photo one time")
            }
        }
        .padding(8)
    }

    private func label(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
            Text(text)
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(tint.opacity(0.15), in: .capsule)
    }

    private func reveal() async {
        guard let attachment = message.attachments.first(where: { $0.isImage }) else { return }
        if !attachment.isDownloaded {
            await service.downloadAttachment(attachment, in: conversationId)
        }
        guard let data = service.attachmentPlaintext(attachment),
              let ui = SafeImage.image(from: data) else {
            unavailable = true
            return
        }
        sensitiveHidden = await SensitiveContent.isSensitive(image: ui, cacheKey: attachment.id)
        image = ui
        viewed = true
        // Delete the ciphertext and attachment row right after display so it
        // can't be shown or re-downloaded again.
        // Every attachment goes, not just the one shown: a modified sender
        // could otherwise attach more that stay viewable.
        let all = message.attachments
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            for attachment in all { service.deleteViewOnceAttachment(attachment, in: conversationId) }
        }
    }
}

// MARK: - In-app browser

import SafariServices

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// The red recording light; pulses while recording, steady when paused.
private struct RecordingDot: View {
    let isPaused: Bool
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(isPaused ? Color.secondary : Color.red)
            .frame(width: 9, height: 9)
            .opacity(dim && !isPaused ? 0.3 : 1)
            .animation(isPaused ? .default : .easeInOut(duration: 0.7).repeatForever(), value: dim)
            .onAppear { dim = true }
    }
}

/// Live input levels while recording, newest on the right.
/// The whole recording, shrunk to fit, filling in as it plays.
private struct RecordingReview: View {
    let levels: [Float]
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 2
            let count = max(12, min(48, Int(geo.size.width / 4)))
            let bars = Self.resample(levels, to: count)
            let width = max(1.5, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, level in
                    Capsule()
                        .fill(Double(index) / Double(count) < progress ? Color.accentColor : Color.secondary.opacity(0.6))
                        .frame(width: width, height: max(3, geo.size.height * CGFloat(level)))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// Peak level per bar.
    static func resample(_ levels: [Float], to count: Int) -> [Float] {
        guard !levels.isEmpty else { return Array(repeating: 0.08, count: count) }
        return (0..<count).map { i in
            let lower = i * levels.count / count
            let upper = max(lower + 1, (i + 1) * levels.count / count)
            return levels[lower..<min(upper, levels.count)].max() ?? 0.08
        }
    }
}

private struct RecordingLevels: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { geo in
            let count = VoiceRecorder.levelCount
            let padded = Array(repeating: Float(0.08), count: max(0, count - levels.count)) + levels.suffix(count)
            let spacing: CGFloat = 2
            let width = max(1.5, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(padded.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(Color.secondary)
                        .frame(width: width, height: max(3, geo.size.height * CGFloat(level)))
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.linear(duration: 0.1), value: levels)
        }
    }
}

/// Relay's own short sounds for messages sent and received while the chat is
/// open. They follow the ring/silent switch and can be turned off in
/// Settings → Chats.
enum InChatSounds {
    static let enabledKey = "relay.inChatSounds"

    enum Kind { case sent, received }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private static var soundIds: [Kind: SystemSoundID] = [:]

    static func play(_ kind: Kind) {
        guard isEnabled else { return }
        if soundIds[kind] == nil,
           let url = Bundle.main.url(forResource: kind == .sent ? "relay-sent" : "relay-received", withExtension: "caf") {
            var id: SystemSoundID = 0
            if AudioServicesCreateSystemSoundID(url as CFURL, &id) == noErr { soundIds[kind] = id }
        }
        guard let id = soundIds[kind] else { return }
        AudioServicesPlaySystemSound(id)
    }
}

/// Lets a photo be dragged out to another app. iPad only: on iPhone a long
/// press belongs to the message menu.
private struct DragOutImage: ViewModifier {
    let image: UIImage?

    func body(content: Content) -> some View {
        if let image, UIDevice.current.userInterfaceIdiom == .pad {
            content.onDrag { NSItemProvider(object: image) }
        } else {
            content
        }
    }
}
