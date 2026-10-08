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
        RelayWidgetEntry(date: .now, contacts: [])
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
        return RelayWidgetEntry(date: .now, contacts: Array(contacts))
    }
}

// MARK: - Views

private struct ContactCell: View {
    let item: RelayWidgetEntry.ContactItem

    var body: some View {
        Link(destination: URL(string: "relay://conversation/\(item.id)")!) {
            VStack(spacing: 5) {
                // Who you talk to is private: redacted when the widget shows
                // on a locked device (Lock Screen, StandBy).
                avatarView
                    .privacySensitive()
                Text(item.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: 64)
                    .privacySensitive()
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var avatarView: some View {
        Group {
            if let data = item.avatarData, let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.accentColor.opacity(0.18)
                    Text(item.initials)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(.circle)
    }
}

struct RelayWidgetExtensionEntryView: View {
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
        .supportedFamilies([.systemMedium])
    }
}

#Preview(as: .systemMedium) {
    RelayWidgetExtension()
} timeline: {
    RelayWidgetEntry(date: .now, contacts: [
        .init(id: "1", displayName: "Alice", initials: "A", avatarData: nil),
        .init(id: "2", displayName: "Bob", initials: "B", avatarData: nil),
        .init(id: "3", displayName: "Carol", initials: "C", avatarData: nil),
    ])
}
