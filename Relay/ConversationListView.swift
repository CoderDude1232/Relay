//
//  ConversationListView.swift
//  Relay
//

import SecureStorage
import SwiftUI

struct ConversationListView: View {
    let service: MessagingService

    @State private var showingNewConversation = false
    @State private var showingNewGroup = false
    @State private var newUsername = ""
    @State private var newConversationError: String?
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if service.conversations.isEmpty {
                    ContentUnavailableView(
                        "No Conversations",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Start a conversation with the compose button.")
                    )
                } else {
                    List(service.conversations) { conversation in
                        NavigationLink(value: conversation.id) {
                            ConversationRow(conversation: conversation, service: service)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Chats")
            .navigationDestination(for: String.self) { conversationId in
                ChatView(service: service, conversationId: conversationId)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ConnectionBadge(state: service.connectionState)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingNewConversation = true
                        } label: {
                            Label("New Chat", systemImage: "person")
                        }
                        Button {
                            showingNewGroup = true
                        } label: {
                            Label("New Group", systemImage: "person.3")
                        }
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .sheet(isPresented: $showingNewGroup) {
                NewGroupView(service: service) { conversationId in
                    path.append(conversationId)
                }
            }
            .alert("New Conversation", isPresented: $showingNewConversation) {
                TextField("Username", text: $newUsername)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Start") { startConversation() }
                Button("Cancel", role: .cancel) { newUsername = "" }
            } message: {
                Text(newConversationError ?? "Enter the username to message.")
            }
        }
    }

    private func startConversation() {
        let username = newUsername.trimmingCharacters(in: .whitespaces)
        newUsername = ""
        guard !username.isEmpty else { return }
        Task {
            do {
                let conversationId = try await service.startConversation(username: username)
                path.append(conversationId)
                newConversationError = nil
            } catch {
                newConversationError = "No user named “\(username)” was found."
                showingNewConversation = true
            }
        }
    }
}

private struct ConversationRow: View {
    let conversation: Conversation
    let service: MessagingService

    // Groups carry their name in peerUsername; 1:1s resolve through the
    // service so a custom name (nickname) takes precedence.
    private var displayName: String {
        if conversation.isGroup {
            return conversation.peerUsername ?? "Group"
        }
        return service.displayName(forAccount: conversation.peerAccount)
    }

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: displayName, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    if conversation.isGroup {
                        Image(systemName: "person.3.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(displayName)
                        .font(.headline)
                    Spacer()
                    if let timestamp = conversation.lastMessageAt {
                        Text(Self.relativeLabel(timestamp))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(conversation.lastMessageBody ?? "No messages yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private static func relativeLabel(_ millis: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(millis) / 1000)
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if Calendar.current.isDateInYesterday(date) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

private struct ConnectionBadge: View {
    let state: MessagingService.ConnectionState

    var body: some View {
        switch state {
        case .connected:
            EmptyView()
        case .connecting:
            ProgressView()
        case .disconnected:
            Image(systemName: "wifi.slash")
                .foregroundStyle(.secondary)
        }
    }
}
