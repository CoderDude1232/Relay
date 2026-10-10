//
//  SiriSendHandler.swift
//  Relay
//
//  Handles "Send a message with Relay" (Siri, CarPlay, Shortcuts) inside the
//  app, which iOS launches in the background for it — so the message actually
//  goes out now. The Intents extension (RelayIntents) can only queue it until
//  the app next runs, so it stays as the fallback.
//

import Intents
import SecureStorage
import UIKit

/// Siri may call in on any thread, so the class is nonisolated and hops to the
/// main actor for app state.
nonisolated final class SiriSendHandler: NSObject, INSendMessageIntentHandling, @unchecked Sendable {
    private weak var appDelegate: AppDelegate?

    init(appDelegate: AppDelegate) { self.appDelegate = appDelegate }

    func resolveRecipients(
        for intent: INSendMessageIntent,
        with completion: @escaping ([INSendMessageRecipientResolutionResult]) -> Void
    ) {
        let requested = intent.recipients ?? []
        Task { @MainActor in
            completion(Self.resolve(requested))
        }
    }

    @MainActor
    private static func resolve(_ requested: [INPerson]) -> [INSendMessageRecipientResolutionResult] {
        let conversations = ShareBridge.readConversations()
        guard !requested.isEmpty else {
            let people = conversations.map(person)
            return people.isEmpty ? [.needsValue()] : [.disambiguation(with: people)]
        }
        return requested.map { person in
            if let id = person.customIdentifier, conversations.contains(where: { $0.id == id }) {
                return .success(with: person)
            }
            let query = (person.displayName).lowercased()
            let matches = conversations.filter { $0.displayName.lowercased().contains(query) }.map(Self.person)
            switch matches.count {
            case 0: return .unsupported()
            case 1: return .success(with: matches[0])
            default: return .disambiguation(with: matches)
            }
        }
    }

    func resolveContent(for intent: INSendMessageIntent, with completion: @escaping (INStringResolutionResult) -> Void) {
        if let text = intent.content, !text.isEmpty {
            completion(.success(with: text))
        } else {
            completion(.needsValue())
        }
    }

    func handle(intent: INSendMessageIntent, completion: @escaping (INSendMessageIntentResponse) -> Void) {
        guard let conversationId = intent.recipients?.first?.customIdentifier, !conversationId.isEmpty,
              let text = intent.content, !text.isEmpty
        else {
            completion(INSendMessageIntentResponse(code: .failure, userActivity: nil))
            return
        }
        Task { @MainActor in
            let task = UIApplication.shared.beginBackgroundTask(withName: "relay.siriSend")
            defer { UIApplication.shared.endBackgroundTask(task) }
            // Launched in the background: wait for the account to finish starting.
            for _ in 0..<40 {
                if let model = self.appDelegate?.model, case .ready = model.phase { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            if let model = self.appDelegate?.model, case .ready(let service) = model.phase {
                await service.sendMessage(text, in: conversationId)
            } else {
                // Couldn't start (e.g. storage locked): send on next launch.
                ShareBridge.writePendingShare(PendingShare(
                    conversationId: conversationId, text: text,
                    imageData: nil, imageUTI: nil, fileData: nil, filename: nil
                ))
            }
            completion(INSendMessageIntentResponse(code: .success, userActivity: nil))
        }
    }

    @MainActor
    private static func person(_ conv: ShareConversationSummary) -> INPerson {
        var name = PersonNameComponents()
        name.givenName = conv.displayName
        return INPerson(
            personHandle: INPersonHandle(value: conv.id, type: .unknown),
            nameComponents: name, displayName: conv.displayName,
            image: ShareBridge.readAvatar(forConversationId: conv.id).map { INImage(imageData: $0) },
            contactIdentifier: nil, customIdentifier: conv.id
        )
    }
}
