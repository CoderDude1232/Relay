//
//  RelayWidgetExtension.swift
//  RelayWidgetExtension
//

import SwiftUI
import UIKit
import WidgetKit

// MARK: - Timeline model

/// Relay's accent (the app's AccentColor).
private let relayAccent = Color(red: 0xF6 / 255, green: 0x3B / 255, blue: 1)

struct RelayWidgetEntry: TimelineEntry {
    let date: Date
    let contacts: [ContactItem]
    let totalUnread: Int

    struct ContactItem: Identifiable {
        let id: String
        let displayName: String
        let initials: String
        let avatarData: Data?
        let unread: Int
    }
}

// MARK: - Provider

struct RelayWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> RelayWidgetEntry {
        RelayWidgetEntry(date: .now, contacts: [], totalUnread: 0)
    }

    func getSnapshot(in context: Context, completion: @escaping (RelayWidgetEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RelayWidgetEntry>) -> Void) {
        // The app reloads the widget when its chats change; this is a fallback.
        let refresh = Calendar.current.date(byAdding: .minute, value: 30, to: .now)!
        completion(Timeline(entries: [makeEntry()], policy: .after(refresh)))
    }

    private func makeEntry() -> RelayWidgetEntry {
        let all = ShareBridge.readConversations()
        let contacts = all.prefix(4).map { conv in
            RelayWidgetEntry.ContactItem(
                id: conv.id,
                displayName: conv.displayName,
                initials: conv.initials,
                avatarData: ShareBridge.readAvatar(forConversationId: conv.id),
                unread: conv.unreadCount ?? 0
            )
        }
        return RelayWidgetEntry(date: .now, contacts: Array(contacts),
                                totalUnread: all.reduce(0) { $0 + ($1.unreadCount ?? 0) })
    }
}

// MARK: - Views

/// The same colours as avatars in the app.
private func avatarColor(_ name: String) -> Color {
    let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green]
    var hash = 0
    for scalar in name.unicodeScalars { hash = (hash &* 31 &+ Int(scalar.value)) }
    return palette[Int(hash.magnitude % UInt(palette.count))]
}

private struct WidgetAvatar: View {
    let item: RelayWidgetEntry.ContactItem
    let size: CGFloat

    var body: some View {
        Group {
            if let data = item.avatarData, let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(avatarColor(item.displayName).gradient)
                    Text(item.initials)
                        .font(.system(size: size * 0.36, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .overlay(alignment: .topTrailing) {
            if item.unread > 0 {
                Text(item.unread > 99 ? "99+" : "\(item.unread)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(relayAccent, in: .capsule)
                    .overlay(Capsule().strokeBorder(.background, lineWidth: 2))
                    .offset(x: 4, y: -2)
            }
        }
    }
}

private struct ContactCell: View {
    let item: RelayWidgetEntry.ContactItem

    var body: some View {
        Link(destination: URL(string: "relay://conversation/\(item.id)")!) {
            VStack(spacing: 5) {
                // Who you talk to is private: redacted when the widget shows
                // on a locked device (Lock Screen, StandBy).
                WidgetAvatar(item: item, size: 50)
                    .privacySensitive()
                Text(item.displayName)
                    .font(.system(size: 11, weight: item.unread > 0 ? .semibold : .medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: 64)
                    .privacySensitive()
            }
        }
        .buttonStyle(.plain)
    }
}

private struct WidgetHeader: View {
    let totalUnread: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .foregroundStyle(relayAccent)
            Text("Relay")
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
            if totalUnread > 0 {
                Text("\(totalUnread) unread")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(relayAccent)
                    .privacySensitive()
            }
        }
    }
}

struct RelayWidgetExtensionEntryView: View {
    let entry: RelayWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if entry.contacts.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 24))
                    .foregroundStyle(relayAccent)
                Text("Open Relay to start\na conversation")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if family == .systemSmall {
            small
        } else {
            VStack(spacing: 10) {
                WidgetHeader(totalUnread: entry.totalUnread)
                HStack(spacing: 0) {
                    ForEach(entry.contacts) { contact in
                        ContactCell(item: contact)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(0..<max(0, 4 - entry.contacts.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    /// Small: the top chat, and how many messages are waiting.
    private var small: some View {
        let top = entry.contacts[0]
        return Link(destination: URL(string: "relay://conversation/\(top.id)")!) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    WidgetAvatar(item: top, size: 44)
                        .privacySensitive()
                    Spacer(minLength: 0)
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.caption)
                        .foregroundStyle(relayAccent)
                }
                Spacer(minLength: 0)
                Text(top.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .privacySensitive()
                Text(entry.totalUnread > 0 ? "\(entry.totalUnread) unread" : "All caught up")
                    .font(.caption)
                    .foregroundStyle(entry.totalUnread > 0 ? relayAccent : .secondary)
                    .privacySensitive()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Widget definition

struct RelayWidgetExtension: Widget {
    let kind = "RelayWidgetExtension"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RelayWidgetProvider()) { entry in
            RelayWidgetExtensionEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Relay")
        .description("Your recent chats and unread messages, one tap away.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#Preview(as: .systemMedium) {
    RelayWidgetExtension()
} timeline: {
    RelayWidgetEntry(date: .now, contacts: [
        .init(id: "1", displayName: "Alice", initials: "A", avatarData: nil, unread: 2),
        .init(id: "2", displayName: "Bob", initials: "B", avatarData: nil, unread: 0),
        .init(id: "3", displayName: "Carol", initials: "C", avatarData: nil, unread: 0),
        .init(id: "4", displayName: "Dan", initials: "D", avatarData: nil, unread: 5),
    ], totalUnread: 7)
}
