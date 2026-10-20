//
//  ScheduledMessagesView.swift
//  Relay
//

import SecureStorage
import SwiftUI

struct ScheduledMessagesView: View {
    let service: MessagingService

    @State private var messages: [MessagingService.ScheduledMessage] = []
    @State private var confirmCancel: MessagingService.ScheduledMessage?

    private let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    var body: some View {
        Group {
            if messages.isEmpty {
                ContentUnavailableView(
                    "No Scheduled Messages",
                    systemImage: "clock.badge.checkmark",
                    description: Text("Messages you schedule will appear here.")
                )
            } else {
                List {
                    ForEach(messages) { msg in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                                Text(relativeTime(for: msg.scheduledAt))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(conversationName(for: msg.conversationId))
                                .font(.footnote.weight(.semibold))
                            Text(msg.body)
                                .font(.subheadline)
                                .lineLimit(2)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Cancel", role: .destructive) {
                                confirmCancel = msg
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .modifier(ThemedPageBackground())
        .navigationTitle("Scheduled")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refresh() }
        .confirmationDialog(
            "Cancel scheduled message?",
            isPresented: Binding(
                get: { confirmCancel != nil },
                set: { if !$0 { confirmCancel = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let msg = confirmCancel {
                Button("Cancel Message", role: .destructive) {
                    service.cancelScheduled(id: msg.id)
                    refresh()
                }
            }
        }
    }

    private func refresh() {
        messages = service.scheduledMessages()
    }

    private func relativeTime(for timestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func conversationName(for id: String) -> String {
        guard let conv = service.conversations.first(where: { $0.id == id }) else { return id }
        if let groupId = conv.groupId {
            return service.displayName(forAccount: groupId)
        }
        return service.displayName(forAccount: conv.peerAccount)
    }
}
