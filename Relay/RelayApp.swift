//
//  RelayApp.swift
//  Relay
//
//  Created by Ethan Daly on 18/7/2026.
//

import SwiftUI
import UIKit
import UserNotifications

@main
struct RelayApp: App {
    @State private var model = AppModel()
    @State private var appearance = ChatAppearance()
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(appearance)
                .task {
                    appDelegate.model = model
                    model.boot()
                    appDelegate.requestPushAuthorization()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background: model.enterBackground()
                    case .active: model.enterForeground()
                    default: break
                    }
                }
        }
    }
}

/// Handles remote-notification registration; the APNs device token is handed
/// to `AppModel`, which uploads it to the relay once a session exists.
final class AppDelegate: NSObject, UIApplicationDelegate {
    weak var model: AppModel?

    func requestPushAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        model?.setAPNSDeviceToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        // Non-fatal: the app still works over the live WebSocket; only
        // background wake-ups are unavailable without a token.
        NSLog("Relay: remote notification registration failed: \(error)")
    }
}
