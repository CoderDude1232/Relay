//
//  RelayChatPreview.swift
//
//  A compact Relay chat (header, recent bubbles, chat theme) drawn from the
//  app's encrypted recent-chat snapshot. The same file is copied into
//  RelaySiriUI and RelayNotificationContent; keep the copies identical.
//

import CryptoKit
import Foundation
import Security
import SwiftUI
import UIKit

// MARK: - Snapshot

/// Mirrors `RecentChatsSnapshot` in RelayCore.
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

enum ChatPreviewStore {
    static let appGroupId = "group.app.relaymsg"
    private static let fileName = "siri-preview.bin"
    private static let wallpaperFileName = "siri-wallpaper.bin"
    private static let keychainService = "app.relaymsg.siri-preview"
    private static let avatarDirName = "relay-avatars"

    private static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }

    static func load() -> SiriPreviewSnapshot? {
        guard let json = read(fileName) else { return nil }
        return try? JSONDecoder().decode(SiriPreviewSnapshot.self, from: json)
    }

    static func wallpaperPhoto() -> UIImage? {
        read(wallpaperFileName).flatMap(UIImage.init(data:))
    }

    private static func read(_ name: String) -> Data? {
        guard let url = container?.appendingPathComponent(name),
              let sealed = try? Data(contentsOf: url),
              let key = readKey(),
              let box = try? AES.GCM.SealedBox(combined: sealed)
        else { return nil }
        return try? AES.GCM.open(box, using: SymmetricKey(data: key))
    }

    static func avatar(forConversationId id: String) -> UIImage? {
        guard !id.isEmpty,
              let url = container?.appendingPathComponent(avatarDirName, isDirectory: true).appendingPathComponent(id),
              let stored = try? Data(contentsOf: url), let data = ShareSeal.open(stored)
        else { return nil }
        return UIImage(data: data)
    }

    /// Whether notifications may show message text ("relay.notificationPrivacy" == full).
    static var notificationPreviewsFull: Bool {
        UserDefaults(suiteName: appGroupId)?.string(forKey: "relay.notificationPrivacy") == "full"
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

struct ChatPreviewTheme {
    static let accent = Color(red: 0xF6 / 255, green: 0x3B / 255, blue: 0xFF / 255)

    let bubble: LinearGradient
    let bubbleShadow: Color
    let wallpaper: LinearGradient?
    let photo: UIImage?

    var hasWallpaper: Bool { wallpaper != nil || photo != nil }

    init(snapshot: SiriPreviewSnapshot?) {
        let stops = (snapshot?.bubble ?? "").split(separator: "-").compactMap { Color(relayHex: String($0)) }
        let a = stops.first ?? Self.accent
        let b = stops.count > 1 ? stops[1] : a
        bubble = LinearGradient(colors: [a, b], startPoint: .topLeading, endPoint: .bottomTrailing)
        bubbleShadow = a
        photo = snapshot?.wallpaper == "photo" ? ChatPreviewStore.wallpaperPhoto() : nil

        let wallpaperStops: [String]? = switch snapshot?.wallpaper {
        case "sunset":   ["FF7E5F", "FEB47B"]
        case "ocean":    ["2193B0", "6DD5ED"]
        case "forest":   ["134E5E", "71B280"]
        case "twilight": ["4B2E83", "9D50BB"]
        case "rose":     ["C94B8F", "F6A5C0"]
        case "graphite": ["1C1C1E", "3A3A3C"]
        case "aurora":   ["0D1431", "1B0F2B"]
        case "dusk":     ["25111F", "2B1810"]
        case "midnight": ["0A101F", "121B31"]
        default: nil
        }
        if let s = wallpaperStops, let top = Color(relayHex: s[0]), let bottom = Color(relayHex: s[1]) {
            wallpaper = LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
        } else {
            wallpaper = nil
        }
    }
}

extension Color {
    init?(relayHex hex: String) {
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}

// MARK: - View

struct ChatPreviewView: View {
    enum Pending {
        /// Siri is asking what to say.
        case composing
        /// The outgoing message, with a status caption.
        case outgoing(String, status: String?)
        /// A just-received message (notification).
        case incoming(String, sender: String?)
    }

    let name: String
    let isGroup: Bool
    let avatar: UIImage?
    let history: [SiriPreviewSnapshot.Message]
    let pending: Pending?
    let theme: ChatPreviewTheme
    var showsHeader = true
    /// Fill the available height, with messages anchored to the bottom.
    var fillsHeight = false

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader { header }
            if fillsHeight { Spacer(minLength: 0) }
            VStack(spacing: 6) {
                ForEach(Array(history.enumerated()), id: \.offset) { _, message in
                    row(message)
                }
                pendingRow
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            if let photo = theme.photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else if let wallpaper = theme.wallpaper {
                wallpaper
            } else {
                Color(.systemBackground)
            }
        }
    }

    private var captionStyle: AnyShapeStyle {
        !theme.hasWallpaper ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.85))
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
                        .font(.system(size: 9))
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
                    ChatPreviewTheme.accent.opacity(0.18)
                    if isGroup {
                        Image(systemName: "person.3.fill")
                            .font(.system(size: 13, weight: .semibold))
                    } else {
                        Text(initials)
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                .foregroundStyle(ChatPreviewTheme.accent)
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(.circle)
    }

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    @ViewBuilder
    private func row(_ message: SiriPreviewSnapshot.Message) -> some View {
        if message.text.hasPrefix("call:") {
            HStack(spacing: 5) {
                Image(systemName: "phone.fill")
                Text(message.text.dropFirst("call:".count))
            }
            .font(.caption)
            .foregroundStyle(captionStyle)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
        } else {
            bubble(message.text, outgoing: message.outgoing, sender: message.sender)
        }
    }

    @ViewBuilder
    private var pendingRow: some View {
        switch pending {
        case .composing:
            HStack {
                Spacer(minLength: 48)
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().frame(width: 7, height: 7)
                    }
                }
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(theme.bubble.opacity(0.55), in: .rect(cornerRadius: 18, style: .continuous))
            }
        case .outgoing(let text, let status):
            bubble(text, outgoing: true, sender: nil)
            if let status {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(captionStyle)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 4)
            }
        case .incoming(let text, let sender):
            bubble(text, outgoing: false, sender: sender)
        case nil:
            EmptyView()
        }
    }

    private func bubble(_ text: String, outgoing: Bool, sender: String?) -> some View {
        HStack {
            if outgoing { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 2) {
                if let sender {
                    Text(sender)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(ChatPreviewTheme.accent)
                }
                Text(text)
                    .font(.system(size: 15))
                    .lineLimit(6)
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

// MARK: - Hosting

/// Pins a SwiftUI view into a view controller and measures its height.
final class ChatPreviewHost {
    private var controller: UIHostingController<ChatPreviewView>?

    @MainActor
    func show(_ view: ChatPreviewView, in parent: UIViewController, width: CGFloat) -> CGFloat {
        let hc: UIHostingController<ChatPreviewView>
        if let controller {
            controller.rootView = view
            hc = controller
        } else {
            hc = UIHostingController(rootView: view)
            hc.view.backgroundColor = .clear
            controller = hc
            parent.addChild(hc)
            parent.view.addSubview(hc.view)
            hc.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                hc.view.leadingAnchor.constraint(equalTo: parent.view.leadingAnchor),
                hc.view.trailingAnchor.constraint(equalTo: parent.view.trailingAnchor),
                hc.view.topAnchor.constraint(equalTo: parent.view.topAnchor),
                hc.view.bottomAnchor.constraint(equalTo: parent.view.bottomAnchor),
            ])
            hc.didMove(toParent: parent)
        }
        let size = hc.view.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return ceil(size.height)
    }
}
