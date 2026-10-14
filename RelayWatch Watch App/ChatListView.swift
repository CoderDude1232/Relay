//
//  ChatListView.swift
//  RelayWatch Watch App
//

import SwiftUI
import UIKit

struct ChatListView: View {
    @Environment(WatchSession.self) private var session

    var body: some View {
        @Bindable var session = session
        NavigationStack(path: $session.path) {
            Group {
                if session.snapshot.chats.isEmpty {
                    emptyState
                } else {
                    List(session.snapshot.chats) { chat in
                        NavigationLink(value: chat.id) {
                            ChatRow(chat: chat, avatar: session.avatar(for: chat.id))
                        }
                        .accessibilityIdentifier("chat-\(chat.id)")
                    }
                }
            }
            .navigationTitle("Relay")
            .navigationDestination(for: String.self) { id in
                ChatDetailView(chatId: id)
            }
        }
        .onAppear { session.refresh() }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: session.hasReceived ? "bubble.left.and.bubble.right" : "iphone")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(session.hasReceived ? "No chats yet" : "Open Relay on your iPhone to see your chats here.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

private struct ChatRow: View {
    let chat: WatchSnapshot.Chat
    let avatar: UIImage?

    var body: some View {
        HStack(spacing: 8) {
            WatchAvatar(name: chat.name, isGroup: chat.isGroup, image: avatar, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(chat.name)
                    .font(.headline)
                    .lineLimit(1)
                if let preview = chat.preview {
                    Text(preview)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if chat.unread > 0 {
                Circle()
                    .fill(.tint)
                    .frame(width: 9, height: 9)
                    .accessibilityLabel("\(chat.unread) unread")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct WatchAvatar: View {
    let name: String
    let isGroup: Bool
    var image: UIImage?
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.25))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(.circle)
            } else if isGroup {
                Image(systemName: "person.3.fill")
                    .font(.system(size: size * 0.32, weight: .semibold))
            } else {
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .semibold))
            }
        }
        .foregroundStyle(Color.accentColor)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var initials: String { Self.initials(for: name) }

    /// Up to two initials: "Ada Lovelace" is "AL".
    static func initials(for name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}

extension WatchSnapshot.Chat {
    /// The chat list's second line: the last message, "You: " if it was ours.
    var preview: String? {
        guard let last = messages.last else { return nil }
        return last.outgoing ? "You: \(last.text)" : last.text
    }
}
