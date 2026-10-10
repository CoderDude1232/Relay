//
//  RelayWatchApp.swift
//  RelayWatch Watch App
//

import SwiftUI
import UserNotifications
import WatchKit

@main
struct RelayWatchApp: App {
    @WKApplicationDelegateAdaptor private var delegate: WatchAppDelegate

    var body: some Scene {
        WindowGroup {
            ChatListView()
                .environment(delegate.session)
        }
    }
}

/// Opens the chat when a Relay notification is tapped on the watch.
final class WatchAppDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    let session = WatchSession()

    func applicationDidFinishLaunching() {
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let chatId = response.notification.request.content.userInfo["conversationId"] as? String ?? ""
        let isDefault = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        Task { @MainActor in
            if isDefault, !chatId.isEmpty { self.session.open(chatId: chatId) }
            completionHandler()
        }
    }
}
