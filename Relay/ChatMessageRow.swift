//
//  ChatMessageRow.swift
//  Relay
//
//  Message rows in a chat: swipe-to-reply, the bubble, the long-press
//  reaction/action menu, and reaction badges. Split out of ChatView.swift.
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

// MARK: - Message row (gestures)

/// Wraps a bubble with swipe-to-reply plus custom quick reactions and actions.
struct MessageRow: View {
    /// Bubbles never grow past this, so lines stay readable on iPad.
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
    @State private var confirmDelete = false

    private var bubble: some View {
        MessageBubble(
            message: message, position: position, peerName: peerName,
            service: service, conversationId: conversationId, isGroup: isGroup,
            isCurrentSearchMatch: isCurrentSearchMatch, onInfo: onInfo
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
        content
            .accessibilityElement(children: isPlainText && !isSelectionMode ? .combine : .contain)
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
                    Spacer(minLength: 56)
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
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        service.toggleReaction("❤️", on: message)
                    },
                    onReply: onReply
                )
                // Readable line length on iPad and wide windows.
                .frame(maxWidth: Self.maxBubbleWidth, alignment: message.isOutgoing ? .trailing : .leading)

                if !message.isOutgoing { Spacer(minLength: 56) }
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

struct MessageBubble: View {
    @Environment(\.relayIsMessageRequest) private var inRequestChat
    let message: StoredMessage
    let position: BubblePosition
    let peerName: String
    let service: MessagingService
    let conversationId: String
    let isGroup: Bool
    var isCurrentSearchMatch = false
    var onInfo: () -> Void = {}
    /// When false, renders only the bubble core, without spacers or avatar, so
    /// the row can align it and use it as the context-menu source view.
    var embedsAlignment: Bool = true

    @Environment(ChatAppearance.self) private var appearance
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
                        Spacer(minLength: 56)
                    } else if position.closesGroup {
                        // Avatar only on the last bubble of a run.
                        AvatarView(name: avatarName, size: 28, imageData: avatarData)
                    } else {
                        Color.clear.frame(width: 28, height: 1)
                    }

                    coreColumn
                        .frame(maxWidth: MessageRow.maxBubbleWidth,
                               alignment: message.isOutgoing ? .trailing : .leading)

                    if !message.isOutgoing { Spacer(minLength: 56) }
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
                Text(service.displayName(forAccount: message.senderAccount ?? ""))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
                    .padding(.leading, 4)
            }
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
                }
                attachmentStack
                let displayBody = message.body.hasPrefix("~once~")
                    ? String(message.body.dropFirst("~once~".count)) : message.body
                if !displayBody.isEmpty {
                    HStack(alignment: .lastTextBaseline, spacing: 7) {
                        Text(formattedBody(displayBody))
                            .fixedSize(horizontal: false, vertical: true)
                        metadataRow
                    }
                    if message.editedAt != nil {
                        Text("edited")
                            .font(.caption2)
                            .foregroundStyle(message.isOutgoing ? .white.opacity(0.65) : .secondary)
                    }
                    if let url = displayBody.firstURL, message.isOutgoing || !inRequestChat {
                        LinkPreviewView(url: url, isOutgoing: message.isOutgoing,
                                        fetchAllowed: message.isOutgoing && message.status != .received
                                            && abs(Date().timeIntervalSince1970 * 1000 - Double(message.timestamp)) < 120_000)
                    }
                } else {
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
                    requiresBiometric: mediaRequiresBiometric
                )
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

    private func formattedBody(_ text: String) -> AttributedString {
        let cacheKey = "\(service.username ?? "")\u{1}\(text)"
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
        if Self.formattedBodyCache.count > 800 { Self.formattedBodyCache.removeAll() }
        Self.formattedBodyCache[cacheKey] = base
        return base
    }

    private var timeLabel: String {
        Date(timeIntervalSince1970: Double(message.timestamp) / 1000)
            .formatted(date: .omitted, time: .shortened)
    }

    private var metadataRow: some View { metadataRow(onBubble: true) }

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

struct MessageActionSpec: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    var role: ButtonRole? = nil
    let action: () -> Void
}

struct NativeMenuBubble: UIViewRepresentable {
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

        host.view.addInteraction(UIContextMenuInteraction(delegate: coord))

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

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate, UIGestureRecognizerDelegate {
        var parent: NativeMenuBubble
        let host: UIHostingController<AnyView>
        weak var sourceView: UIView?
        private let reactionBar = ReactionBarWindowController()

        init(_ parent: NativeMenuBubble) {
            self.parent = parent
            self.host = UIHostingController(rootView: parent.bubble)
            self.host.view.backgroundColor = .clear
            super.init()
        }

        @objc func handleDoubleTap() { parent.onDoubleTap() }

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
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        // MARK: UIContextMenuInteractionDelegate

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                guard let self else { return nil }
                let children = self.parent.actions.map { spec in
                    UIAction(title: spec.label,
                             image: UIImage(systemName: spec.icon),
                             attributes: spec.role == .destructive ? .destructive : []) { _ in
                        spec.action()
                    }
                }
                return UIMenu(title: "", children: children)
            }
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                    animator: (any UIContextMenuInteractionAnimating)?) {
            guard let source = sourceView else { return }
            reactionBar.show(
                from: source, isOutgoing: parent.isOutgoing,
                reactions: parent.reactions, current: parent.currentReaction
            ) { [weak self] emoji in
                self?.parent.onReact(emoji)
                self?.reactionBar.hide()
            }
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    willEndFor configuration: UIContextMenuConfiguration,
                                    animator: (any UIContextMenuInteractionAnimating)?) {
            reactionBar.hide()
        }
    }
}

/// Reaction bar shown in a small overlay window above the message while the
/// context menu is open. Sized to its content so taps outside it reach the menu,
/// whose dismissal (willEnd) hides the bar.
final class ReactionBarWindowController {
    private var window: UIWindow?
    private var hosting: UIHostingController<ReactionBarView>?

    func show(from source: UIView, isOutgoing: Bool, reactions: [String],
              current: String?, onReact: @escaping (String) -> Void) {
        guard window == nil, let scene = source.window?.windowScene else { return }

        let hc = UIHostingController(rootView: ReactionBarView(reactions: reactions, current: current, onReact: onReact))
        hc.view.backgroundColor = .clear
        let size = hc.sizeThatFits(in: CGSize(width: 500, height: 80))

        let src = source.convert(source.bounds, to: nil)
        let screen = scene.screen.bounds
        var x = isOutgoing ? src.maxX - size.width : src.minX
        x = max(12, min(x, screen.width - size.width - 12))
        var y = src.minY - size.height - 12
        if y < 60 { y = src.maxY + 12 }  // no room above: place below

        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        w.backgroundColor = .clear
        let root = UIViewController()
        root.view.backgroundColor = .clear
        hc.view.frame = CGRect(origin: .zero, size: size)
        root.view.addSubview(hc.view)
        w.rootViewController = root
        w.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        w.isHidden = false

        hc.view.alpha = 0
        hc.view.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        UIView.animate(withDuration: 0.2, delay: 0.03, options: [.curveEaseOut]) {
            hc.view.alpha = 1
            hc.view.transform = .identity
        }

        window = w
        hosting = hc
    }

    func hide() {
        window?.isHidden = true
        window = nil
        hosting = nil
    }
}

struct ReactionBarView: View {
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

struct ReactionBadges: View {
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

struct ReactionEmojiID: Identifiable {
    let emoji: String
    var id: String { emoji }
}

struct ReactionAttributionSheet: View {
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
