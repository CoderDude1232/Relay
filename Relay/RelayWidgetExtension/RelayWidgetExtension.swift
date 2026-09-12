//
//  RelayWidgetExtension.swift
//  RelayWidgetExtension
//

import SwiftUI
import UIKit
import WidgetKit

// MARK: - Timeline model

struct RelayWidgetEntry: TimelineEntry {
    let date: Date
    let contacts: [ContactItem]
    let totalUnread: Int

    struct ContactItem: Identifiable {
        let id: String
        let displayName: String
        let initials: String
        let avatarData: Data?
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
        let refresh = Calendar.current.date(byAdding: .minute, value: 15, to: .now)!
        completion(Timeline(entries: [makeEntry()], policy: .after(refresh)))
    }

    private func makeEntry() -> RelayWidgetEntry {
        let contacts = ShareBridge.readConversations().prefix(3).map { conv in
            RelayWidgetEntry.ContactItem(
                id: conv.id,
                displayName: conv.displayName,
                initials: conv.initials,
                avatarData: ShareBridge.readAvatar(forConversationId: conv.id)
            )
        }
        return RelayWidgetEntry(
            date: .now,
            contacts: Array(contacts),
            totalUnread: ShareBridge.readUnreadCount()
        )
    }
}

// MARK: - Shared avatar view

private struct WidgetAvatarView: View {
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
                    Color.accentColor.opacity(0.18)
                    Text(item.initials)
                        .font(.system(size: size * 0.35, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
    }
}

// MARK: - Medium widget view (existing)

private struct ContactCell: View {
    let item: RelayWidgetEntry.ContactItem

    var body: some View {
        Link(destination: URL(string: "relay://conversation/\(item.id)")!) {
            VStack(spacing: 5) {
                WidgetAvatarView(item: item, size: 56)
                Text(item.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: 64)
            }
        }
        .buttonStyle(.plain)
    }
}

struct RelayWidgetExtensionEntryView: View {
    let entry: RelayWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(entry: entry)
        case .accessoryCircular:
            CircularWidgetView(entry: entry)
        case .accessoryRectangular:
            RectangularWidgetView(entry: entry)
        default:
            MediumWidgetView(entry: entry)
        }
    }
}

// Medium: three top contacts side-by-side
private struct MediumWidgetView: View {
    let entry: RelayWidgetEntry

    var body: some View {
        if entry.contacts.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
                Text("Open Relay to start\na conversation")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                ForEach(entry.contacts) { contact in
                    ContactCell(item: contact)
                        .frame(maxWidth: .infinity)
                }
                ForEach(0..<max(0, 3 - entry.contacts.count), id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 8)
        }
    }
}

// Small: top contact + unread badge
private struct SmallWidgetView: View {
    let entry: RelayWidgetEntry

    var body: some View {
        if let first = entry.contacts.first {
            Link(destination: URL(string: "relay://conversation/\(first.id)")!) {
                VStack(spacing: 8) {
                    WidgetAvatarView(item: first, size: 60)
                    Text(first.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    if entry.totalUnread > 0 {
                        Text("\(min(entry.totalUnread, 99)) unread")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.plain)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("Relay")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// Circular lock-screen / StandBy: unread count or chat icon
private struct CircularWidgetView: View {
    let entry: RelayWidgetEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            if entry.totalUnread > 0 {
                VStack(spacing: 1) {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 9))
                    Text("\(min(entry.totalUnread, 99))")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                }
            } else {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 14))
            }
        }
    }
}

// Rectangular lock-screen: most recent conversation name + unread count
private struct RectangularWidgetView: View {
    let entry: RelayWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Relay", systemImage: "bubble.left.and.bubble.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if let first = entry.contacts.first {
                Text(first.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if entry.totalUnread > 0 {
                    Text("\(entry.totalUnread) unread message\(entry.totalUnread == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No new messages")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No conversations yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .description("Your top conversations, one tap away.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

#Preview(as: .systemMedium) {
    RelayWidgetExtension()
} timeline: {
    RelayWidgetEntry(date: .now, contacts: [
        .init(id: "1", displayName: "Alice", initials: "A", avatarData: nil),
        .init(id: "2", displayName: "Bob", initials: "B", avatarData: nil),
        .init(id: "3", displayName: "Carol", initials: "C", avatarData: nil),
    ], totalUnread: 5)
}

#Preview(as: .accessoryCircular) {
    RelayWidgetExtension()
} timeline: {
    RelayWidgetEntry(date: .now, contacts: [], totalUnread: 3)
}

#Preview(as: .accessoryRectangular) {
    RelayWidgetExtension()
} timeline: {
    RelayWidgetEntry(date: .now, contacts: [
        .init(id: "1", displayName: "Alice", initials: "A", avatarData: nil),
    ], totalUnread: 2)
}
