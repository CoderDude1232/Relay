//
//  ChatView.swift
//  Relay
//
//  1:1 chat: date separators, grouped bubbles with tails only on the last
//  of a run, incoming avatars, and per-message time/status. Liquid Glass
//  stays on the chrome (compose bar); bubbles are flat fills per the
//  guidance on limiting glass effects.
//
//  Interactions (Signal-inspired): long-press a message for a reaction tray
//  and actions (reply/copy/delete/info), swipe a bubble to reply, reaction
//  badges, jumbomoji for all-emoji messages, an emoji picker in the
//  composer, and live typing indicators.
//

import PhotosUI
import RelayKit
import SecureStorage
import SwiftUI
import UIKit

struct ChatView: View {
    let service: MessagingService
    let conversationId: String

    @State private var draft = ""
    @State private var replyingTo: StoredMessage?
    @State private var actionTarget: StoredMessage?
    @State private var showingComposerEmoji = false
    @State private var photoItem: PhotosPickerItem?
    @State private var pendingImage: MessagingService.PendingAttachment?
    @State private var showingVerification = false
    @State private var showingGroupInfo = false
    @State private var verification: MessagingService.PeerVerification?

    private var isGroup: Bool { conversation?.isGroup == true }
    @State private var lastTypingSentAt: Date?
    @FocusState private var composerFocused: Bool

    private var conversation: Conversation? {
        service.conversations.first { $0.id == conversationId }
    }

    private var peerName: String {
        conversation?.peerUsername ?? String((conversation?.peerAccount ?? "Chat").prefix(8))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(displayItems) { item in
                        switch item {
                        case .dateSeparator(let id, let label):
                            Text(label)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 12)
                                .id(id)
                        case .message(let message, let position):
                            if message.senderAccount == MessagingService.systemSender {
                                Text(message.body)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .id(message.id)
                            } else {
                                MessageRow(
                                    message: message,
                                    position: position,
                                    peerName: peerName,
                                    service: service,
                                    conversationId: conversationId,
                                    isGroup: isGroup,
                                    onLongPress: { actionTarget = message },
                                    onReply: { beginReply(message) }
                                )
                                .id(message.id)
                            }
                        }
                    }
                    if service.peerTyping {
                        TypingIndicatorView(peerName: peerName)
                            .id(Self.typingAnchor)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: service.activeMessages.count) { scrollToBottom(proxy) }
            .onChange(of: service.peerTyping) { if service.peerTyping { scrollToBottom(proxy) } }
        }
        .navigationTitle(peerName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    if isGroup { showingGroupInfo = true } else { showingVerification = true }
                } label: {
                    VStack(spacing: 0) {
                        AvatarView(name: peerName, size: 30)
                        HStack(spacing: 3) {
                            if let symbol = verification?.state.titleSymbol {
                                Image(systemName: symbol.name)
                                    .foregroundStyle(symbol.tint)
                            }
                            Text(peerName)
                                .font(.caption2.weight(.semibold))
                        }
                    }
                }
                .tint(.primary)
            }
        }
        .safeAreaInset(edge: .top) {
            if verification?.state == .changed {
                safetyNumberChangedBanner
            }
        }
        .safeAreaInset(edge: .bottom) {
            composeBar
        }
        .sheet(isPresented: $showingVerification, onDismiss: refreshVerification) {
            VerificationView(service: service, conversationId: conversationId, peerName: peerName)
        }
        .sheet(isPresented: $showingGroupInfo) {
            GroupInfoView(
                service: service,
                conversationId: conversationId,
                ownAccountId: service.credentials.accountId
            )
        }
        .sheet(item: $actionTarget) { message in
            MessageActionsSheet(
                message: message,
                isOwnAuthor: isOwn(message),
                peerName: peerName,
                canUnsend: service.canUnsend(message),
                onReact: { service.toggleReaction($0, on: message) },
                onReply: { beginReply(message) },
                onUnsend: { service.unsend(message) },
                onDelete: { service.deleteMessage(message.id, in: conversationId) }
            )
        }
        .sheet(isPresented: $showingComposerEmoji) {
            EmojiPicker { draft += $0 }
        }
        .onAppear {
            service.openConversation(conversationId)
            refreshVerification()
        }
        .onChange(of: service.activeMessages.count) { refreshVerification() }
        .onChange(of: draft) { _, newValue in updateTypingState(for: newValue) }
        .onDisappear {
            if lastTypingSentAt != nil { service.sendTyping(.stopped, in: conversationId) }
            service.closeConversation()
        }
    }

    private static let typingAnchor = "typing-indicator"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.snappy) {
            if service.peerTyping {
                proxy.scrollTo(Self.typingAnchor, anchor: .bottom)
            } else if let last = service.activeMessages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
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

    private func refreshVerification() {
        verification = service.peerVerification(for: conversationId)
    }

    /// Whether a message was authored by the local user (drives quote/reply
    /// attribution).
    private func isOwn(_ message: StoredMessage) -> Bool {
        message.isOutgoing
    }

    private func quoteAuthor(of message: StoredMessage) -> String {
        message.isOutgoing ? service.credentials.accountId : (conversation?.peerAccount ?? "")
    }

    private func beginReply(_ message: StoredMessage) {
        replyingTo = message
        composerFocused = true
    }

    // MARK: - Compose bar

    private var composeBar: some View {
        VStack(spacing: 8) {
            if let replyingTo {
                ReplyPreviewBar(
                    message: replyingTo,
                    isOwnAuthor: isOwn(replyingTo),
                    peerName: peerName,
                    onCancel: { self.replyingTo = nil }
                )
                .padding(.horizontal)
            }
            if let pendingImage {
                PendingAttachmentBar(image: pendingImage, onCancel: { clearPendingImage() })
                    .padding(.horizontal)
            }
            GlassEffectContainer {
                HStack(spacing: 10) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                    }

                    Button {
                        showingComposerEmoji = true
                    } label: {
                        Image(systemName: "face.smiling")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)

                    TextField("Message \(peerName)…", text: $draft, axis: .vertical)
                        .lineLimit(1...5)
                        .focused($composerFocused)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .glassEffect()

                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up")
                            .fontWeight(.bold)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!canSend)
                }
                .padding(.horizontal)
                .padding(.bottom, 6)
            }
        }
        .onChange(of: photoItem) { _, item in loadPickedPhoto(item) }
    }

    private var canSend: Bool {
        pendingImage != nil || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func loadPickedPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { return }
            pendingImage = MessagingService.PendingAttachment(
                data: data,
                contentType: "image/jpeg",
                filename: nil,
                width: Int(image.size.width * image.scale),
                height: Int(image.size.height * image.scale)
            )
        }
    }

    private func clearPendingImage() {
        pendingImage = nil
        photoItem = nil
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        let reply = replyingTo.map {
            QuotedMessage(
                targetTimestamp: $0.timestamp,
                author: quoteAuthor(of: $0),
                text: String($0.body.prefix(240))
            )
        }
        let attachments = pendingImage.map { [$0] } ?? []
        draft = ""
        replyingTo = nil
        clearPendingImage()
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
            if lastTypingSentAt == nil || now.timeIntervalSince(lastTypingSentAt!) > 4 {
                service.sendTyping(.started, in: conversationId)
                lastTypingSentAt = now
            }
        }
    }

    // MARK: - Grouping

    private enum DisplayItem: Identifiable {
        case dateSeparator(id: String, label: String)
        case message(StoredMessage, position: BubblePosition)

        var id: String {
            switch self {
            case .dateSeparator(let id, _): id
            case .message(let message, _): message.id
            }
        }
    }

    /// Messages within this window and from the same side group together.
    private static let groupWindowMillis: Int64 = 5 * 60 * 1000

    private var displayItems: [DisplayItem] {
        let messages = service.activeMessages
        var items: [DisplayItem] = []
        let calendar = Calendar.current

        for (index, message) in messages.enumerated() {
            let date = Date(timeIntervalSince1970: Double(message.timestamp) / 1000)
            let previous = index > 0 ? messages[index - 1] : nil
            let next = index + 1 < messages.count ? messages[index + 1] : nil

            if previous == nil || !calendar.isDate(
                Date(timeIntervalSince1970: Double(previous!.timestamp) / 1000),
                inSameDayAs: date
            ) {
                items.append(.dateSeparator(id: "day-\(message.id)", label: Self.dayLabel(date)))
            }

            let groupsWithPrevious = previous.map {
                $0.isOutgoing == message.isOutgoing
                    && message.timestamp - $0.timestamp < Self.groupWindowMillis
                    && calendar.isDate(
                        Date(timeIntervalSince1970: Double($0.timestamp) / 1000),
                        inSameDayAs: date
                    )
            } ?? false
            let groupsWithNext = next.map {
                $0.isOutgoing == message.isOutgoing
                    && $0.timestamp - message.timestamp < Self.groupWindowMillis
                    && calendar.isDate(
                        Date(timeIntervalSince1970: Double($0.timestamp) / 1000),
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

enum BubblePosition {
    case single, first, middle, last

    var closesGroup: Bool { self == .single || self == .last }
}

/// The badge shown next to the peer's name in the chat title. Unverified
/// peers get no badge (the default, unremarkable state).
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

/// Wraps a bubble with swipe-to-reply and long-press-for-actions.
private struct MessageRow: View {
    let message: StoredMessage
    let position: BubblePosition
    let peerName: String
    let service: MessagingService
    let conversationId: String
    let isGroup: Bool
    let onLongPress: () -> Void
    let onReply: () -> Void

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        MessageBubble(
            message: message,
            position: position,
            peerName: peerName,
            service: service,
            conversationId: conversationId,
            isGroup: isGroup,
            onTapReactions: onLongPress
        )
        .offset(x: dragOffset)
        .background(alignment: message.isOutgoing ? .trailing : .leading) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .foregroundStyle(.secondary)
                .opacity(Double(min(1, abs(dragOffset) / 55)))
                .padding(.horizontal, 24)
        }
        .contentShape(.rect)
        .onLongPressGesture(minimumDuration: 0.4) { onLongPress() }
        .gesture(replyDrag)
    }

    private var replyDrag: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragOffset = max(-70, min(70, value.translation.width * 0.5))
            }
            .onEnded { value in
                if abs(value.translation.width) > 52 {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onReply()
                }
                withAnimation(.snappy) { dragOffset = 0 }
            }
    }
}

// MARK: - Bubble

private struct MessageBubble: View {
    let message: StoredMessage
    let position: BubblePosition
    let peerName: String
    let service: MessagingService
    let conversationId: String
    let isGroup: Bool
    let onTapReactions: () -> Void

    private var showsSenderLabel: Bool {
        isGroup && !message.isOutgoing && (position == .single || position == .first)
            && !(message.senderAccount ?? "").isEmpty
    }

    private var isJumbo: Bool {
        message.replyTo == nil && message.body.isJumbomojiCandidate && message.attachments.isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.isOutgoing {
                Spacer(minLength: 56)
            } else {
                // Avatar only on the last bubble of a run, like iMessage.
                if position.closesGroup {
                    AvatarView(name: peerName, size: 28)
                } else {
                    Color.clear.frame(width: 28, height: 1)
                }
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 3) {
                if showsSenderLabel {
                    Text(service.displayName(forAccount: message.senderAccount ?? ""))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                        .padding(.leading, 4)
                }
                bubbleContent
                    .overlay(alignment: message.isOutgoing ? .bottomLeading : .bottomTrailing) {
                        if !message.reactions.isEmpty {
                            ReactionBadges(chips: reactionChips, onTap: onTapReactions)
                                .offset(x: message.isOutgoing ? -6 : 6, y: 14)
                        }
                    }
                    .padding(.bottom, message.reactions.isEmpty ? 0 : 16)

                if position.closesGroup {
                    HStack(spacing: 4) {
                        Text(timeLabel)
                        if message.isOutgoing {
                            statusView
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                }
            }

            if !message.isOutgoing { Spacer(minLength: 56) }
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
            Text(message.body)
                .font(.system(size: 52))
                .padding(.vertical, 2)
        } else if !message.attachments.isEmpty && message.body.isEmpty && message.replyTo == nil {
            // Media-only message: show the image(s) with no bubble fill.
            attachmentStack
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if let quote = message.replyTo {
                    QuotedContentView(quote: quote, isOutgoing: message.isOutgoing, peerName: peerName)
                }
                attachmentStack
                if !message.body.isEmpty {
                    Text(message.body)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(
                message.isOutgoing ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.secondary),
                in: .rect(cornerRadii: cornerRadii)
            )
            .foregroundStyle(message.isOutgoing ? .white : .primary)
        }
    }

    @ViewBuilder
    private var attachmentStack: some View {
        ForEach(message.attachments) { attachment in
            AttachmentImageView(attachment: attachment, service: service, conversationId: conversationId)
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

    /// Tight corners on the grouped side, like iMessage runs.
    private var cornerRadii: RectangleCornerRadii {
        let full: CGFloat = 18
        let tight: CGFloat = 5
        let topGrouped = position == .middle || position == .last
        let bottomGrouped = position == .first || position == .middle
        return RectangleCornerRadii(
            topLeading: !message.isOutgoing && topGrouped ? tight : full,
            bottomLeading: !message.isOutgoing && bottomGrouped ? tight : full,
            bottomTrailing: message.isOutgoing && bottomGrouped ? tight : full,
            topTrailing: message.isOutgoing && topGrouped ? tight : full
        )
    }

    private var timeLabel: String {
        Date(timeIntervalSince1970: Double(message.timestamp) / 1000)
            .formatted(date: .omitted, time: .shortened)
    }

    @ViewBuilder
    private var statusView: some View {
        switch message.status {
        case .sending:
            Image(systemName: "clock")
        case .sent:
            Image(systemName: "checkmark")
        case .delivered:
            Image(systemName: "checkmark.circle")
        case .read:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.tint)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        case .received:
            EmptyView()
        }
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
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(chips) { chip in
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
                .background(Color(.secondarySystemBackground), in: .capsule)
                .overlay {
                    Capsule().strokeBorder(
                        chip.mine ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.systemBackground)),
                        lineWidth: chip.mine ? 1.5 : 2
                    )
                }
            }
        }
        .contentShape(.rect)
        .onTapGesture(perform: onTap)
    }
}

// MARK: - Quote rendering

private struct QuotedContentView: View {
    let quote: QuotedMessage
    let isOutgoing: Bool
    let peerName: String

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(isOutgoing ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(quote.text.isEmpty ? "Message" : quote.text)
                    .font(.footnote)
                    .lineLimit(2)
                    .opacity(isOutgoing ? 0.9 : 0.8)
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
            VStack(alignment: .leading, spacing: 2) {
                Text("Reply to \(isOwnAuthor ? "You" : peerName)")
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
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(.fill.tertiary, in: .rect(cornerRadius: 12))
    }
}

// MARK: - Attachments

/// Renders an image attachment: downloads the ciphertext on first view,
/// decrypts it to memory, and displays it. Plaintext never touches disk.
private struct AttachmentImageView: View {
    let attachment: StoredAttachment
    let service: MessagingService
    let conversationId: String

    @State private var image: UIImage?
    @State private var failed = false

    private var height: CGFloat {
        guard attachment.width > 0, attachment.height > 0 else { return 240 }
        let aspect = CGFloat(attachment.width) / CGFloat(attachment.height)
        return max(120, min(320, 240 / aspect))
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.fill.tertiary)
                    Image(systemName: failed ? "exclamationmark.triangle" : "photo")
                        .foregroundStyle(.secondary)
                    if !failed { ProgressView() }
                }
            }
        }
        .frame(width: 240, height: height)
        .clipShape(.rect(cornerRadius: 16))
        .task(id: attachment.id) { await load() }
    }

    private func load() async {
        if !attachment.isDownloaded {
            await service.downloadAttachment(attachment, in: conversationId)
        }
        if let data = service.attachmentPlaintext(attachment), let ui = UIImage(data: data) {
            image = ui
        } else {
            failed = true
        }
    }
}

/// A thumbnail of the picked-but-unsent image shown above the composer.
private struct PendingAttachmentBar: View {
    let image: MessagingService.PendingAttachment
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let ui = UIImage(data: image.data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(.rect(cornerRadius: 8))
            }
            Text("Photo")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(.fill.tertiary, in: .rect(cornerRadius: 12))
    }
}

// MARK: - Typing indicator

private struct TypingIndicatorView: View {
    let peerName: String
    @State private var phase = 0

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            AvatarView(name: peerName, size: 28)
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .frame(width: 7, height: 7)
                        .foregroundStyle(.secondary)
                        .opacity(phase == index ? 1 : 0.3)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(.fill.secondary, in: .rect(cornerRadius: 18))
            Spacer(minLength: 56)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(350))
                withAnimation(.easeInOut(duration: 0.2)) { phase = (phase + 1) % 3 }
            }
        }
    }
}

// MARK: - Long-press actions sheet

private struct MessageActionsSheet: View {
    let message: StoredMessage
    let isOwnAuthor: Bool
    let peerName: String
    let canUnsend: Bool
    let onReact: (String) -> Void
    let onReply: () -> Void
    let onUnsend: () -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showingEmojiPicker = false

    private var myReaction: String? {
        message.reactions.first(where: \.isOutgoing)?.emoji
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !message.isDeleted {
                    reactionTray
                        .padding()
                }
                List {
                    if !message.isDeleted {
                        Button {
                            dismiss()
                            onReply()
                        } label: {
                            Label("Reply", systemImage: "arrowshape.turn.up.left")
                        }
                        if !message.body.isEmpty {
                            Button {
                                UIPasteboard.general.string = message.body
                                dismiss()
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                        }
                    }
                    NavigationLink {
                        MessageInfoView(message: message, isOwnAuthor: isOwnAuthor, peerName: peerName)
                    } label: {
                        Label("Info", systemImage: "info.circle")
                    }
                    if canUnsend {
                        Button(role: .destructive) {
                            dismiss()
                            onUnsend()
                        } label: {
                            Label("Unsend for Everyone", systemImage: "arrow.uturn.backward")
                        }
                    }
                    Button(role: .destructive) {
                        dismiss()
                        onDelete()
                    } label: {
                        Label("Delete for Me", systemImage: "trash")
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showingEmojiPicker) {
                EmojiPicker { emoji in
                    onReact(emoji)
                    dismiss()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var reactionTray: some View {
        HStack(spacing: 8) {
            ForEach(quickReactions, id: \.self) { emoji in
                Button {
                    onReact(emoji)
                    dismiss()
                } label: {
                    Text(emoji)
                        .font(.system(size: 30))
                        .padding(6)
                        .background(
                            myReaction == emoji ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.clear),
                            in: .circle
                        )
                }
                .buttonStyle(.plain)
            }
            Button {
                showingEmojiPicker = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .background(.fill.tertiary, in: .circle)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MessageInfoView: View {
    let message: StoredMessage
    let isOwnAuthor: Bool
    let peerName: String

    var body: some View {
        List {
            LabeledContent("From", value: isOwnAuthor ? "You" : peerName)
            LabeledContent("Sent", value: fullTimestamp)
            if message.isOutgoing {
                LabeledContent("Status", value: statusLabel)
            }
        }
        .navigationTitle("Info")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var fullTimestamp: String {
        Date(timeIntervalSince1970: Double(message.timestamp) / 1000)
            .formatted(date: .abbreviated, time: .standard)
    }

    private var statusLabel: String {
        switch message.status {
        case .sending: "Sending…"
        case .sent: "Sent"
        case .delivered: "Delivered"
        case .read: "Read"
        case .failed: "Failed"
        case .received: "Received"
        }
    }
}
