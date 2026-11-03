//
//  RelayLinkEmbed.swift
//  Relay
//
//  Cards for Relay's own links in messages: contact links, one-time contact
//  invites, group invites, call links and proxies. The sender's app fills in
//  the name and photo from what it already knows (no website fetch) and sends
//  them as the message's link preview. The button goes through the same
//  confirmation as opening the link.
//

import RelayCore
import RelayKit
import SecureStorage
import SwiftUI
import UIKit

extension AppModel {
    private static let deferredInviteKey = "relay.deferredInvite"

    /// An invite opened or pasted before there was an account here. Kept
    /// across launches, so it survives sign-up, then opened like any invite.
    var deferredInvite: URL? {
        get {
            access(keyPath: \.deferredInviteVersion)
            return UserDefaults.standard.string(forKey: Self.deferredInviteKey).flatMap(URL.init(string:))
        }
        set {
            withMutation(keyPath: \.deferredInviteVersion) {
                UserDefaults.standard.set(newValue?.absoluteString, forKey: Self.deferredInviteKey)
            }
        }
    }

    /// Keeps an invite (https://relaymsg.app/… or relay://…) for after sign-up.
    /// False if it isn't an invite.
    @discardableResult
    func deferInvite(_ url: URL) -> Bool {
        guard let canonical = RelayLink.canonicalURL(url), RelayLink(canonical)?.isInvite == true else { return false }
        deferredInvite = canonical
        return true
    }

    /// Opens the kept invite once there's an account.
    func openDeferredInvite() {
        guard isReady, let url = deferredInvite else { return }
        deferredInvite = nil
        if let link = RelayLink(url) { open(link, url: url) }
    }

    /// The same confirmation flow as opening the link from outside Relay.
    func open(_ link: RelayLink, url: URL) {
        switch link {
        case .add(let username): pendingDeepLinkUsername = username
        case .contactInvite(let token): pendingContactInviteToken = token
        case .group(let token, let fragment):
            pendingGroupInviteToken = fragment.isEmpty ? token : "\(token)#\(fragment)"
        case .call:
            if let parsed = CallManager.parseCallLink(url) { pendingCallLink = parsed }
        case .proxy(let address): pendingProxy = address
        }
    }
}

enum RelayLink: Equatable {
    case add(username: String)
    case contactInvite(token: String)
    case group(token: String, fragment: String)
    case call(callId: String)
    case proxy(RelayProxy.Address)

    init?(_ url: URL) {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host()?.lowercased() == "relaymsg.app" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        if parts.first == "proxy" {
            guard let address = RelayProxy.parse(url.absoluteString) else { return nil }
            self = .proxy(address)
            return
        }
        guard parts.count >= 2, !parts[1].isEmpty else { return nil }
        switch parts[0] {
        case "add": self = .add(username: parts[1])
        case "c": self = .contactInvite(token: parts[1])
        case "g": self = .group(token: parts[1], fragment: url.fragment ?? "")
        case "call":
            guard CallManager.parseCallLink(url) != nil else { return nil }
            self = .call(callId: parts[1])
        default: return nil
        }
    }

    /// Invites lead to a person, group or call; proxy links are settings.
    var isInvite: Bool {
        if case .proxy = self { return false }
        return true
    }

    /// The https form of a relay:// link (relay://add/x → https://relaymsg.app/add/x).
    static func canonicalURL(_ url: URL) -> URL? {
        if url.scheme?.lowercased() == "https", url.host()?.lowercased() == "relaymsg.app" { return url }
        guard url.scheme == "relay", let host = url.host() else { return nil }
        let path: String
        switch host {
        case "add": path = "add"
        case "contact": path = "c"
        case "join": path = "g"
        case "call": path = "call"
        default: return nil
        }
        guard let value = url.pathComponents.dropFirst().first, !value.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "relaymsg.app"
        components.path = "/\(path)/\(value)"
        components.fragment = url.fragment
        return components.url
    }

    var symbol: String {
        switch self {
        case .add, .contactInvite: "person.crop.circle.badge.plus"
        case .group: "person.3.fill"
        case .call: "video.fill"
        case .proxy: "network.badge.shield.half.filled"
        }
    }

    var kindLabel: String {
        switch self {
        case .add: "Relay contact"
        case .contactInvite: "Contact invite"
        case .group: "Group invite"
        case .call: "Call link"
        case .proxy: "Relay proxy"
        }
    }

    var fallbackTitle: String {
        switch self {
        case .add(let username): "@\(username)"
        case .contactInvite: "Add me on Relay"
        case .group: "Join a group"
        case .call: "Join a call"
        case .proxy(let address): address.display
        }
    }

    var actionTitle: String {
        switch self {
        case .add: "Message"
        case .contactInvite: "Add Contact"
        case .group: "View Group"
        case .call: "Join Call"
        case .proxy: "Use Proxy"
        }
    }

    // MARK: Sender: the preview, from what this device already knows

    /// Built locally (nothing is fetched from the website). Group invites are
    /// read from the relay's invite store, as opening the link would.
    @MainActor
    static func preview(for urlText: String, service: MessagingService) async -> MessageStore.LinkPreview? {
        guard let url = URL(string: urlText), let link = RelayLink(url) else { return nil }
        var title: String?
        var image: Data?
        switch link {
        case .add(let username):
            if username.caseInsensitiveCompare(service.username ?? "") == .orderedSame {
                title = service.myDisplayName ?? "@\(username)"
                image = service.myAvatarData
            }
        case .group(let token, let fragment):
            if let preview = try? await service.previewGroupInvite(token: token, fragment: fragment) {
                title = "\(preview.groupName) · \(preview.memberCount) \(preview.memberCount == 1 ? "member" : "members")"
                if let id = preview.existingConversationId { image = service.group(for: id)?.avatarData }
            }
        case .call(let callId):
            title = CallLinkStore.shared.link(callId)?.name
        case .contactInvite:
            title = service.myDisplayName
            image = service.myAvatarData
        case .proxy:
            break
        }
        let thumbnail = image.flatMap { SafeImage.image(from: $0) }.flatMap { LinkPreviewBuilder.thumbnail($0) }
        guard let title, !title.isEmpty else {
            return thumbnail.map { .init(url: urlText, title: "", image: $0) }
        }
        return .init(url: urlText, title: title, image: thumbnail)
    }
}

// MARK: - Card

struct RelayLinkCard: View {
    let link: RelayLink
    let url: URL
    let preview: MessageStore.LinkPreview?
    let isOutgoing: Bool
    let service: MessagingService
    /// The message is only this link: the bubble itself is the card, with
    /// no inner box.
    var standalone = false

    @Environment(AppModel.self) private var model
    @Environment(ChatAppearance.self) private var appearance
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var title: String {
        preview.flatMap { $0.title.isEmpty ? nil : $0.title } ?? link.fallbackTitle
    }
    private var image: UIImage? { preview?.image.flatMap { SafeImage.image(from: $0) } }

    /// Your own contact link does nothing for you.
    private var isOwnContactLink: Bool {
        if case .add(let username) = link {
            return username.caseInsensitiveCompare(service.username ?? "") == .orderedSame
        }
        return false
    }

    var body: some View {
        VStack(spacing: 12) {
            // Large text: the icon goes above, so the words get the width.
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(spacing: 12))
            layout {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    Label(link.kindLabel, systemImage: "lock.fill")
                        .labelStyle(KindLabelStyle())
                        .font(.caption)
                        .opacity(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !isOwnContactLink {
                Button(action: open) {
                    Text(link.actionTitle)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .foregroundStyle(isOutgoing ? AnyShapeStyle(appearance.bubbleTint) : AnyShapeStyle(.white))
                        .background(
                            isOutgoing ? AnyShapeStyle(.white) : AnyShapeStyle(appearance.bubbleTint),
                            in: .capsule
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(standalone ? 0 : 11)
        .frame(width: dynamicTypeSize.isAccessibilitySize ? 290 : 240)
        .background(standalone ? AnyShapeStyle(.clear)
                        : isOutgoing ? AnyShapeStyle(.white.opacity(0.14)) : AnyShapeStyle(.fill.tertiary),
                    in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(link.kindLabel): \(title)")
        .accessibilityAction(named: link.actionTitle) { if !isOwnContactLink { open() } }
    }

    @ViewBuilder
    private var icon: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 46, height: 46)
                .clipShape(.circle)
        } else {
            // Like the voice-message button: white on your bubble, the
            // bubble colour on theirs.
            Image(systemName: link.symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(isOutgoing ? appearance.bubbleTint : .white)
                .frame(width: 46, height: 46)
                .background(isOutgoing ? AnyShapeStyle(.white) : AnyShapeStyle(appearance.bubbleTint.gradient),
                            in: .circle)
        }
    }

    private func open() { model.open(link, url: url) }

    private struct KindLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 4) {
                configuration.icon.font(.caption2)
                configuration.title
            }
        }
    }
}
