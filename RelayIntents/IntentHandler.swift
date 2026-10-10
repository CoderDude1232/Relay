//
//  IntentHandler.swift
//  RelayIntents
//

import Foundation
import Intents
import UIKit

class IntentHandler: INExtension, INSendMessageIntentHandling {

    override func handler(for intent: INIntent) -> Any { return self }

    // MARK: - Resolve recipients

    func resolveRecipients(
        for intent: INSendMessageIntent,
        with completion: @escaping ([INSendMessageRecipientResolutionResult]) -> Void
    ) {
        let conversations = ShareBridge.readConversations()

        guard let requestedNames = intent.recipients, !requestedNames.isEmpty else {
            // No name yet: offer every conversation for disambiguation.
            let people = conversations.map { makePerson(from: $0) }
            completion(people.isEmpty ? [.needsValue()] : [.disambiguation(with: people)])
            return
        }

        var results: [INSendMessageRecipientResolutionResult] = []
        for requested in requestedNames {
            let query = (requested.displayName ?? "").lowercased()
            let matches = conversations
                .filter { $0.displayName.lowercased().contains(query) }
                .map { makePerson(from: $0) }
            switch matches.count {
            case 0:   results.append(.unsupported())
            case 1:   results.append(.success(with: matches[0]))
            default:  results.append(.disambiguation(with: matches))
            }
        }
        completion(results)
    }

    func resolveContent(
        for intent: INSendMessageIntent,
        with completion: @escaping (INStringResolutionResult) -> Void
    ) {
        if let text = intent.content, !text.isEmpty {
            completion(.success(with: text))
        } else {
            completion(.needsValue())
        }
    }

    // MARK: - Confirm

    func confirm(
        intent: INSendMessageIntent,
        completion: @escaping (INSendMessageIntentResponse) -> Void
    ) {
        let activity = NSUserActivity(activityType: NSStringFromClass(INSendMessageIntent.self))
        completion(INSendMessageIntentResponse(code: .ready, userActivity: activity))
    }

    // MARK: - Handle

    func handle(
        intent: INSendMessageIntent,
        completion: @escaping (INSendMessageIntentResponse) -> Void
    ) {
        guard let conversationId = intent.recipients?.first?.customIdentifier,
              !conversationId.isEmpty else {
            let activity = NSUserActivity(activityType: NSStringFromClass(INSendMessageIntent.self))
            completion(INSendMessageIntentResponse(code: .failure, userActivity: activity))
            return
        }

        let pending = PendingShare(
            conversationId: conversationId,
            text: intent.content,
            imageData: nil,
            imageUTI: nil,
            fileData: nil,
            filename: nil
        )
        ShareBridge.writePendingShare(pending)

        // Report success so Siri says "Sent" without launching the app. The app
        // sends the queued PendingShare the next time it becomes active.
        completion(INSendMessageIntentResponse(code: .success, userActivity: nil))
    }

    // MARK: - Helpers

    private func makePerson(from conv: ShareConversationSummary) -> INPerson {
        var components = PersonNameComponents()
        components.givenName = conv.displayName

        // Use the avatar if there is one, otherwise the same initials circle the
        // app draws, so Siri never shows the generic silhouette.
        let image: INImage? = {
            if let data = ShareBridge.readAvatar(forConversationId: conv.id) {
                return INImage(imageData: data)
            }
            guard let ui = makeInitialsImage(conv.initials),
                  let png = ui.pngData() else { return nil }
            return INImage(imageData: png)
        }()

        return INPerson(
            personHandle: INPersonHandle(value: conv.id, type: .unknown),
            nameComponents: components,
            displayName: conv.displayName,
            image: image,
            contactIdentifier: nil,
            customIdentifier: conv.id
        )
    }

    private func makeInitialsImage(_ initials: String) -> UIImage? {
        let size: CGFloat = 120
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { _ in
            UIColor.systemPurple.withAlphaComponent(0.2).setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: size, height: size)).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: size * 0.38, weight: .semibold),
                .foregroundColor: UIColor.systemPurple,
            ]
            let str = initials as NSString
            let strSize = str.size(withAttributes: attrs)
            str.draw(
                at: CGPoint(x: (size - strSize.width) / 2, y: (size - strSize.height) / 2),
                withAttributes: attrs
            )
        }
    }
}
