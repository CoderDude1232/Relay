//
//  NotificationViewController.swift
//  RelayNotificationContent
//
//  Expanded message notification drawn as a Relay chat: recent messages from
//  the app's encrypted snapshot, then the new message, in the chat theme.
//

import SwiftUI
import UIKit
import UserNotifications
import UserNotificationsUI

class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private let host = ChatPreviewHost()
    private let maxHistory = 4

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    func didReceive(_ notification: UNNotification) {
        let content = notification.request.content
        let conversationId = content.userInfo["conversationId"] as? String ?? ""
        let snapshot = ChatPreviewStore.load()
        let conversation = conversationId.isEmpty ? nil : snapshot?.conversations.first { $0.id == conversationId }

        // History only when notifications are allowed to show message text.
        var history = ChatPreviewStore.notificationPreviewsFull ? (conversation?.messages ?? []) : []
        if let last = history.last, !last.outgoing, last.text == content.body {
            history.removeLast()
        }

        let preview = ChatPreviewView(
            name: conversation?.name ?? content.title,
            isGroup: conversation?.isGroup ?? false,
            avatar: ChatPreviewStore.avatar(forConversationId: conversationId),
            history: Array(history.suffix(maxHistory)),
            pending: .incoming(content.body, sender: nil),
            theme: ChatPreviewTheme(snapshot: snapshot)
        )
        let width = view.bounds.width > 0 ? view.bounds.width : UIScreen.main.bounds.width
        let height = host.show(preview, in: self, width: width)
        preferredContentSize = CGSize(width: width, height: height)
    }
}
