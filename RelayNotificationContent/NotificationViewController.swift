//
//  NotificationViewController.swift
//  RelayNotificationContent
//

import SwiftUI
import UIKit
import UserNotifications
import UserNotificationsUI

class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private var hostingController: UIHostingController<RichNotificationView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    func didReceive(_ notification: UNNotification) {
        let content = notification.request.content
        let conversationId = content.userInfo["conversationId"] as? String ?? ""
        let avatarData = conversationId.isEmpty ? nil : ShareBridge.readAvatar(forConversationId: conversationId)

        let notificationView = RichNotificationView(
            senderName: content.title,
            messageBody: content.body,
            avatarData: avatarData
        )

        if let hc = hostingController {
            hc.rootView = notificationView
        } else {
            let hc = UIHostingController(rootView: notificationView)
            hc.view.backgroundColor = .clear
            hostingController = hc
            addChild(hc)
            view.addSubview(hc.view)
            hc.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                hc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                hc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                hc.view.topAnchor.constraint(equalTo: view.topAnchor),
                hc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            hc.didMove(toParent: self)
        }
    }
}

private struct RichNotificationView: View {
    let senderName: String
    let messageBody: String
    let avatarData: Data?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatarView
            VStack(alignment: .leading, spacing: 4) {
                Text(senderName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(messageBody)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    @ViewBuilder
    private var avatarView: some View {
        Group {
            if let data = avatarData, let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.accentColor.opacity(0.18)
                    Text(initials)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(.circle)
    }

    private var initials: String {
        let words = senderName.split(separator: " ").prefix(2)
        return words.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}
