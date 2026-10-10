//
//  IntentViewController.swift
//  RelaySiriUI
//
//  Siri's send-message confirmation, drawn like a Relay chat: the recipient's
//  avatar and name, their last few messages from the app's encrypted snapshot,
//  and the message being sent, in the user's chat theme.
//

import CryptoKit
import Intents
import IntentsUI
import Security
import SwiftUI
import UIKit

class IntentViewController: UIViewController, INUIHostedViewControlling {
    private var hostingController: UIHostingController<SiriChatPreview>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    func configureView(
        for parameters: Set<INParameter>,
        of interaction: INInteraction,
        interactiveBehavior: INUIInteractiveBehavior,
        context: INUIHostedViewContext,
        completion: @escaping (Bool, Set<INParameter>, CGSize) -> Void
    ) {
        guard let intent = interaction.intent as? INSendMessageIntent else {
            completion(false, parameters, .zero)
            return
        }
        let recipient = intent.recipients?.first
        let conversationId = recipient?.customIdentifier ?? recipient?.personHandle?.value ?? ""
        let snapshot = SiriPreviewStore.load()
        let conversation = snapshot?.conversations.first { $0.id == conversationId }
        let name = conversation?.name ?? recipient?.displayName ?? intent.speakableGroupName?.spokenPhrase ?? "Relay"

        let preview = SiriChatPreview(
            name: name,
            isGroup: conversation?.isGroup ?? false,
            avatar: conversationId.isEmpty ? nil : SiriPreviewStore.avatar(forConversationId: conversationId).flatMap(UIImage.init(data:)),
            history: conversation?.messages ?? [],
            draft: intent.content ?? "",
            sent: interaction.intentHandlingStatus == .success,
            theme: SiriChatTheme(snapshot: snapshot)
        )

        let hc: UIHostingController<SiriChatPreview>
        if let existing = hostingController {
            existing.rootView = preview
            hc = existing
        } else {
            hc = UIHostingController(rootView: preview)
            hc.view.backgroundColor = .clear
            hostingController = hc
            addChild(hc)
            view.addSubview(hc.view)
            hc.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                hc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                hc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                hc.view.topAnchor.constraint(equalTo: view.topAnchor),
                hc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            hc.didMove(toParent: self)
        }

        let maxSize = extensionContext?.hostedViewMaximumAllowedSize ?? CGSize(width: 320, height: 400)
        let fitting = hc.sizeThatFits(in: CGSize(width: maxSize.width, height: .greatestFiniteMagnitude))
        completion(true, parameters, CGSize(width: maxSize.width, height: min(fitting.height, maxSize.height)))
    }
}

// MARK: - Snapshot

/// Mirrors `SiriPreviewSnapshot` in the app target.
struct SiriPreviewSnapshot: Codable {
    struct Message: Codable {
        let outgoing: Bool
        let text: String
        let sender: String?
    }
    struct Conversation: Codable {
        let id: String
        let name: String
        let isGroup: Bool
        let messages: [Message]
    }
    let bubble: String?
    let wallpaper: String
    let conversations: [Conversation]
}

enum SiriPreviewStore {
    private static let appGroupId = "group.app.relaymsg"
    private static let fileName = "siri-preview.bin"
    private static let keychainService = "app.relaymsg.siri-preview"
    private static let avatarDirName = "relay-avatars"

    private static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }

    static func load() -> SiriPreviewSnapshot? {
        guard let url = container?.appendingPathComponent(fileName),
              let sealed = try? Data(contentsOf: url),
              let key = readKey(),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let json = try? AES.GCM.open(box, using: SymmetricKey(data: key))
        else { return nil }
        return try? JSONDecoder().decode(SiriPreviewSnapshot.self, from: json)
    }

    static func avatar(forConversationId id: String) -> Data? {
        guard let url = container?.appendingPathComponent(avatarDirName, isDirectory: true)
                .appendingPathComponent(id)
        else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func readKey() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "key",
            kSecAttrAccessGroup as String: appGroupId,
            kSecReturnData as String: true,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, data.count == 32
        else { return nil }
        return data
    }
}

// MARK: - Theme

struct SiriChatTheme {
    static let accent = Color(red: 0xF6 / 255, green: 0x3B / 255, blue: 0xFF / 255)

    let bubble: LinearGradient
    let bubbleShadow: Color
    let wallpaper: LinearGradient?

    init(snapshot: SiriPreviewSnapshot?) {
        let stops = (snapshot?.bubble ?? "").split(separator: "-").compactMap { Color(hex: String($0)) }
        let a = stops.first ?? Self.accent
        let b = stops.count > 1 ? stops[1] : a
        bubble = LinearGradient(colors: [a, b], startPoint: .topLeading, endPoint: .bottomTrailing)
        bubbleShadow = a

        let wallpaperStops: [String]? = switch snapshot?.wallpaper {
        case "sunset":   ["FF7E5F", "FEB47B"]
        case "ocean":    ["2193B0", "6DD5ED"]
        case "forest":   ["134E5E", "71B280"]
        case "twilight": ["4B2E83", "9D50BB"]
        case "rose":     ["C94B8F", "F6A5C0"]
        case "graphite": ["1C1C1E", "3A3A3C"]
        default: nil
        }
        if let s = wallpaperStops, let top = Color(hex: s[0]), let bottom = Color(hex: s[1]) {
            wallpaper = LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
        } else {
            wallpaper = nil
        }
    }
}

extension Color {
    init?(hex: String) {
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}

// MARK: - View

struct SiriChatPreview: View {
    let name: String
    let isGroup: Bool
    let avatar: UIImage?
    let history: [SiriPreviewSnapshot.Message]
    let draft: String
    let sent: Bool
    let theme: SiriChatTheme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(theme.wallpaper == nil ? 1 : 0)
            VStack(spacing: 6) {
                ForEach(Array(history.enumerated()), id: \.offset) { _, message in
                    bubble(message.text, outgoing: message.outgoing, sender: message.sender)
                }
                if !draft.isEmpty {
                    bubble(draft, outgoing: true, sender: nil)
                    HStack {
                        Spacer()
                        Text(sent ? "Sent" : "Not sent yet")
                            .font(.caption2)
                            .foregroundStyle(theme.wallpaper == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.85)))
                    }
                    .padding(.trailing, 4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .background {
            if let wallpaper = theme.wallpaper {
                wallpaper
            } else {
                Color(.systemGroupedBackground)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            avatarView
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 3) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .regular))
                    Text("End-to-end encrypted")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var avatarView: some View {
        Group {
            if let avatar {
                Image(uiImage: avatar)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    SiriChatTheme.accent.opacity(0.18)
                    if isGroup {
                        Image(systemName: "person.3.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SiriChatTheme.accent)
                    } else {
                        Text(initials)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(SiriChatTheme.accent)
                    }
                }
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(.circle)
    }

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    @ViewBuilder
    private func bubble(_ text: String, outgoing: Bool, sender: String?) -> some View {
        HStack {
            if outgoing { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 2) {
                if let sender {
                    Text(sender)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(SiriChatTheme.accent)
                }
                Text(text)
                    .font(.system(size: 15))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                outgoing ? AnyShapeStyle(theme.bubble) : AnyShapeStyle(Color(.systemBackground).opacity(0.92)),
                in: .rect(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                if !outgoing {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.primary.opacity(0.07), lineWidth: 1)
                }
            }
            .shadow(color: outgoing ? theme.bubbleShadow.opacity(0.3) : .black.opacity(0.05), radius: 5, x: 0, y: 2)
            .foregroundStyle(outgoing ? .white : .primary)
            if !outgoing { Spacer(minLength: 48) }
        }
    }
}
