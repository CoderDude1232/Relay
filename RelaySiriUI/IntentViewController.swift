//
//  IntentViewController.swift
//  RelaySiriUI
//
//  Siri's send-message snippets drawn as a Relay chat: while asking what to
//  say, when asking to confirm, and after sending.
//

import Intents
import IntentsUI
import SwiftUI
import UIKit

class IntentViewController: UIViewController, INUIHostedViewControlling {
    private let host = ChatPreviewHost()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    func configureView(
        for parameters: Set<INParameter>,
        of interaction: INInteraction,
        interactiveBehavior: INUIInteractiveBehavior,
        context: INUIHostedViewContext,
        completion: @escaping (Bool, Set<INParameter>, CGSize) -> Void
    ) {
        guard let intent = interaction.intent as? INSendMessageIntent else {
            completion(false, parameters, .zero)
            return
        }
        // Siri may ask once per parameter. The whole chat is drawn for the
        // recipients (or a request with no parameters); other parameters are
        // claimed with an empty view so the chat isn't shown twice.
        if !parameters.isEmpty && !parameters.contains(where: { $0.parameterKeyPath.hasPrefix("recipients") }) {
            completion(true, parameters, .zero)
            return
        }
        let recipient = intent.recipients?.first
        let conversationId = recipient?.customIdentifier ?? recipient?.personHandle?.value ?? ""
        let snapshot = ChatPreviewStore.load()
        let conversation = snapshot?.conversations.first { $0.id == conversationId }
        let name = conversation?.name ?? recipient?.displayName ?? intent.speakableGroupName?.spokenPhrase ?? "Relay"

        let draft = intent.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pending: ChatPreviewView.Pending
        if draft.isEmpty {
            pending = .composing
        } else {
            let status: String? = switch interaction.intentHandlingStatus {
            case .success: "Sent"
            case .inProgress: "Sending…"
            case .failure: "Couldn't send"
            default: nil
            }
            pending = .outgoing(draft, status: status)
        }

        let maxSize = extensionContext?.hostedViewMaximumAllowedSize ?? CGSize(width: 320, height: 400)
        let history = conversation?.messages ?? []
        func preview(_ count: Int, fill: Bool) -> ChatPreviewView {
            ChatPreviewView(
                name: name,
                isGroup: conversation?.isGroup ?? false,
                avatar: ChatPreviewStore.avatar(forConversationId: conversationId),
                history: Array(history.suffix(count)),
                pending: pending,
                theme: ChatPreviewTheme(snapshot: snapshot),
                fillsHeight: fill
            )
        }
        // As many recent messages as fit, newest at the bottom.
        var count = history.count
        while count > 0, host.show(preview(count, fill: false), in: self, width: maxSize.width) > maxSize.height {
            count -= 1
        }
        _ = host.show(preview(count, fill: true), in: self, width: maxSize.width)
        completion(true, parameters, maxSize)
    }
}
