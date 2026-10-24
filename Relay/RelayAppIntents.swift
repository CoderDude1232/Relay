//
//  RelayAppIntents.swift
//  Relay
//
//  Shortcuts and Siri actions: open a chat, send a message, start a call and
//  open Note to Self. Chats come from the encrypted snapshot the share sheet
//  and widget use, so hidden chats never appear here.
//

import AppIntents
import Foundation
import SecureStorage
import UIKit

nonisolated struct ChatEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Relay Chat"
    static let defaultQuery = ChatQuery()

    let id: String
    let name: String
    let isGroup: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: isGroup ? "Group" : nil,
            image: .init(systemName: isGroup ? "person.3.fill" : "person.fill")
        )
    }
}

nonisolated struct ChatQuery: EntityStringQuery {
    private func all() async -> [ChatEntity] {
        await MainActor.run {
            ShareBridge.readConversations().map { ChatEntity(id: $0.id, name: $0.displayName, isGroup: $0.isGroup) }
        }
    }

    func entities(for identifiers: [String]) async throws -> [ChatEntity] {
        await all().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [ChatEntity] {
        await all().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [ChatEntity] {
        await all()
    }
}

/// The running app's messaging service, waiting briefly when iOS has just
/// launched Relay in the background for the intent.
@MainActor
private func readyService() async -> MessagingService? {
    for _ in 0..<40 {
        if let model = AppDelegate.current?.model, case .ready(let service) = model.phase { return service }
        try? await Task.sleep(for: .milliseconds(250))
    }
    return nil
}

private func conversationURL(_ id: String) -> URL {
    URL(string: "relay://conversation/\(id)")!
}

nonisolated struct OpenChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Chat"
    static let description = IntentDescription("Opens a chat in Relay.")
    static let openAppWhenRun = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Chat") var chat: ChatEntity

    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$chat)") }

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(conversationURL(chat.id)))
    }
}

nonisolated struct SendRelayMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Message"
    static let description = IntentDescription("Sends a message in a Relay chat without opening the app.")
    /// Never from the Lock Screen: Siri there could otherwise message anyone.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Chat") var chat: ChatEntity
    @Parameter(title: "Message", inputOptions: String.IntentInputOptions(multiline: true)) var text: String

    static var parameterSummary: some ParameterSummary { Summary("Send \(\.$text) to \(\.$chat)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw $text.needsValueError("What's the message?") }
        let id = chat.id
        let sent = await MainActor.run { () -> Task<Bool, Never> in
            Task { @MainActor in
                let task = UIApplication.shared.beginBackgroundTask(withName: "relay.intentSend")
                defer { UIApplication.shared.endBackgroundTask(task) }
                if let service = await readyService() {
                    await service.sendMessage(message, in: id)
                    return true
                }
                // Storage not available yet (e.g. before first unlock): sent on next launch.
                ShareBridge.writePendingShare(PendingShare(
                    conversationId: id, text: message,
                    imageData: nil, imageUTI: nil, fileData: nil, filename: nil
                ))
                return false
            }
        }
        let now = await sent.value
        return .result(dialog: now ? "Sent to \(chat.name)." : "It'll send to \(chat.name) when Relay next opens.")
    }
}

nonisolated struct StartRelayCallIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Call"
    static let description = IntentDescription("Starts a Relay voice or video call with a chat.")
    static let openAppWhenRun = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Chat") var chat: ChatEntity
    @Parameter(title: "Video", default: false) var video: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Call \(\.$chat)") { \.$video }
    }

    func perform() async throws -> some IntentResult {
        let id = chat.id, name = chat.name, kind: CallKind = video ? .video : .audio
        await MainActor.run {
            Task { @MainActor in
                guard let service = await readyService(),
                      let callManager = AppDelegate.current?.callManager else { return }
                if let group = service.group(for: id) {
                    let others = group.members.filter { $0 != (callManager.ownAccountId ?? "") }
                    await callManager.startGroupCall(groupId: group.id, groupName: group.name,
                                                     participants: others, kind: kind)
                } else if let peer = service.conversations.first(where: { $0.id == id })?.peerAccount,
                          peer != service.noteToSelfAccount, peer != service.relayOfficialAccount {
                    await callManager.startCall(peerAccount: peer, peerName: name, kind: kind)
                }
            }
        }
        return .result()
    }
}

nonisolated struct OpenNoteToSelfIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Note to Self"
    static let description = IntentDescription("Opens your Note to Self chat in Relay.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            Task { @MainActor in
                guard let service = await readyService() else { return }
                let id = await service.ensureNoteToSelf()
                AppDelegate.current?.model?.pendingNotificationConversationId = id
            }
        }
        return .result()
    }
}

nonisolated struct NewRelayMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "New Message"
    static let description = IntentDescription("Starts a new chat in Relay.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "relay://compose")!))
    }
}

nonisolated struct RelayShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendRelayMessageIntent(),
            phrases: [
                "Send a \(.applicationName) message",
                "Message \(\.$chat) on \(.applicationName)",
            ],
            shortTitle: "Send Message",
            systemImageName: "paperplane.fill"
        )
        AppShortcut(
            intent: OpenChatIntent(),
            phrases: [
                "Open \(\.$chat) in \(.applicationName)",
                "Open a \(.applicationName) chat",
            ],
            shortTitle: "Open Chat",
            systemImageName: "bubble.left.and.bubble.right.fill"
        )
        AppShortcut(
            intent: StartRelayCallIntent(),
            phrases: [
                "Call \(\.$chat) on \(.applicationName)",
                "Start a \(.applicationName) call",
            ],
            shortTitle: "Start Call",
            systemImageName: "phone.fill"
        )
        AppShortcut(
            intent: OpenNoteToSelfIntent(),
            phrases: ["Open Note to Self in \(.applicationName)"],
            shortTitle: "Note to Self",
            systemImageName: "note.text"
        )
        AppShortcut(
            intent: NewRelayMessageIntent(),
            phrases: ["New \(.applicationName) message"],
            shortTitle: "New Message",
            systemImageName: "square.and.pencil"
        )
    }
}
