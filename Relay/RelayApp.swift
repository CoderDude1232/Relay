//
//  RelayApp.swift
//  Relay
//
//  Created by Ethan Daly on 18/7/2026.
//

import BackgroundTasks
import CoreSpotlight
import Intents
import RelayKit
import SwiftUI
import UIKit
import UserNotifications

@main
struct RelayApp: App {
    @State private var model = AppModel()
    @State private var appearance = ChatAppearance()
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(appearance)
                // Use the AppDelegate-owned CallManager so it exists before
                // any VoIP push can arrive (even from a killed-app launch).
                .environment(appDelegate.callManager)
                .task {
                    #if DEBUG
                    PrivacyRedactor.runSelfCheck()
                    #endif
                    appDelegate.model = model
                    // Drain any conversationId that arrived via notification tap
                    // before the model was wired (cold-start path).
                    if let id = appDelegate.coldStartConversationId {
                        model.pendingNotificationConversationId = id
                        appDelegate.coldStartConversationId = nil
                    }
                    await model.boot()
                    if model.isReady {
                        wireCallManager()
                        // Only ask for notification permission once there is an
                        // account to notify for — never over the Welcome screen.
                        // For already-registered users this is a no-op prompt-wise
                        // and re-registers for remote notifications each launch.
                        appDelegate.requestPushAuthorization()
                    }
                }
                .onChange(of: model.isReady) { _, isReady in
                    if isReady {
                        wireCallManager()
                        // First time through: right after registration/sign-in.
                        appDelegate.requestPushAuthorization()
                    }
                }
                .onOpenURL { url in
                    guard url.scheme == "relay" else { return }
                    if url.host == "add" {
                        // relay://add/<username>
                        let username = url.pathComponents.dropFirst().first ?? ""
                        guard !username.isEmpty else { return }
                        model.pendingDeepLinkUsername = username
                    } else if url.host == "join" {
                        // relay://join/<token>#<fragment-key>
                        let token = url.pathComponents.dropFirst().first ?? ""
                        guard !token.isEmpty else { return }
                        let frag = url.fragment ?? ""
                        model.pendingGroupInviteToken = frag.isEmpty ? token : "\(token)#\(frag)"
                    } else if url.host == "contact" {
                        // relay://contact/<token> — one-time contact invite
                        let token = url.pathComponents.dropFirst().first ?? ""
                        guard !token.isEmpty else { return }
                        model.pendingContactInviteToken = token
                    } else if url.host == "conversation" {
                        // relay://conversation/<conversationId> — widget tap deeplink
                        let convId = url.pathComponents.dropFirst().first ?? ""
                        guard !convId.isEmpty else { return }
                        model.pendingNotificationConversationId = convId
                    } else if url.host == "pending-share" {
                        // relay://pending-share — opened by the Share Extension after
                        // writing a PendingShare to the shared App Group container.
                        guard case .ready(let service) = model.phase else { return }
                        Task {
                            if let convId = await service.processPendingShare() {
                                model.pendingNotificationConversationId = convId
                            }
                        }
                    }
                }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    // Spotlight tap → open the indexed conversation
                    guard let convId = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                          !convId.isEmpty else { return }
                    model.pendingNotificationConversationId = convId
                }
                .onContinueUserActivity(NSStringFromClass(INSendMessageIntent.self)) { _ in
                    // Siri "send via Relay" → processPendingShare already called in enterForeground
                    guard case .ready(let service) = model.phase else { return }
                    Task {
                        if let convId = await service.processPendingShare() {
                            model.pendingNotificationConversationId = convId
                        }
                    }
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    // Universal Links:
                    //   https://relaymsg.app/add/<username>   (permanent username link)
                    //   https://relaymsg.app/c/<token>        (one-time contact invite)
                    guard let url = activity.webpageURL,
                          url.host == "relaymsg.app",
                          url.pathComponents.count >= 3
                    else { return }
                    let kind = url.pathComponents[1]
                    let value = url.pathComponents[2]
                    guard !value.isEmpty else { return }
                    if kind == "add" {
                        model.pendingDeepLinkUsername = value
                    } else if kind == "c" {
                        model.pendingContactInviteToken = value
                    } else if kind == "g" {
                        // https://relaymsg.app/g/<token>#<fragment-key> — encrypted group invite
                        let frag = url.fragment ?? ""
                        model.pendingGroupInviteToken = frag.isEmpty ? value : "\(value)#\(frag)"
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background:
                        if !appDelegate.callManager.needsSignalingConnection {
                            model.enterBackground()
                            appDelegate.scheduleBackgroundRefresh()
                        }
                        // Refresh the encrypted iCloud backup when leaving the app.
                        if case .ready(let service) = model.phase {
                            Task { await CloudBackupManager.shared.backupNow(service: service) }
                        }
                    case .active:
                        model.enterForeground()
                    default:
                        break
                    }
                }
        }
    }

    private func wireCallManager() {
        guard case .ready(let service) = model.phase else { return }
        let callManager = appDelegate.callManager
        callManager.onSendCallMessage = { msg, account in
            await service.sendCallMessage(msg, to: account)
        }
        callManager.onSendGroupCallMessage = { msg, accounts in
            await service.sendGroupCallMessage(msg, toAccounts: accounts)
        }
        callManager.ownAccountId = service.credentials.accountId
        callManager.onTriggerPush = { account, callId in
            // The VoIP push carries only the call id (no caller name/account/kind).
            await service.triggerCallPush(account: account, callId: callId)
        }
        callManager.nameResolver = { account in
            service.displayName(forAccount: account)
        }
        callManager.isBlockedAccount = { account in
            service.isBlocked(account)
        }
        callManager.groupMembersResolver = { groupId in
            guard let conv = service.conversations.first(where: { $0.groupId == groupId }) else { return nil }
            return service.group(for: conv.id)?.members
        }
        callManager.onAwaitingCallOffer = {
            // A VoIP push woke us for an anonymous call: make sure the socket is
            // up (no-op if already running) and replay any OFFER the NSE already
            // decrypted, so the caller can be identified within the wait window.
            service.start()
            Task { await replayPendingCallOffersDuringWake(service) }
        }
        callManager.onRecordCall = { call in
            service.recordCall(call)
        }
        service.onCallMessage = { info in
            await callManager.handleIncomingCall(info)
        }
        let appModel = model
        service.onNukeReceived = {
            await MainActor.run { appModel.signOut() }
        }
        callManager.onFetchTurnCredentials = {
            try await service.apiClient.fetchTurnCredentials()
        }
        Task { await replayPendingCallOffersDuringWake(service) }
        appDelegate.pushKitDelegate.wire(apiClient: service.apiClient)
    }

    private func replayPendingCallOffersDuringWake(_ service: MessagingService) async {
        for _ in 0..<20 {
            await service.replayPendingCallOffers()
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}

/// Owns the CallManager and PushKitDelegate for the lifetime of the process.
/// Placing them here ensures they exist before any SwiftUI view renders and
/// before any VoIP push can arrive on a killed-app launch.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let bgRefreshTaskId = "app.relaymsg.bg-refresh"

    let callManager = CallManager()
    let pushKitDelegate = PushKitDelegate()
    weak var model: AppModel?
    /// Buffer for notification taps that arrive before the model is wired (cold-start).
    var coldStartConversationId: String?

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.bgRefreshTaskId)
        // Minimum 15 min — iOS decides actual timing based on usage patterns.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Register the background refresh task that drains Siri-queued messages
        // when the main socket has already closed. Must be registered before
        // the app finishes launching.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.bgRefreshTaskId,
            using: nil
        ) { [weak self] task in
            guard let bgTask = task as? BGAppRefreshTask else { return }
            bgTask.expirationHandler = { bgTask.setTaskCompleted(success: false) }
            Task { @MainActor [weak self] in
                await self?.model?.handleBackgroundRefresh()
                self?.scheduleBackgroundRefresh()
                bgTask.setTaskCompleted(success: true)
            }
        }

        pushKitDelegate.start(callManager: callManager)
        UNUserNotificationCenter.current().delegate = self
        let replyAction = UNTextInputNotificationAction(
            identifier: "RELAY_QUICK_REPLY",
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Message"
        )
        let markReadAction = UNNotificationAction(
            identifier: "RELAY_MARK_READ",
            title: "Mark as Read",
            options: []
        )
        let msgCategory = UNNotificationCategory(
            identifier: "RELAY_MESSAGE",
            actions: [replyAction, markReadAction],
            intentIdentifiers: [NSStringFromClass(INSendMessageIntent.self)],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([msgCategory])
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let conversationId = response.notification.request.content.userInfo["conversationId"] as? String ?? ""
        switch response.actionIdentifier {
        case "RELAY_QUICK_REPLY":
            let text = (response as? UNTextInputNotificationResponse)?.userText ?? ""
            guard !text.isEmpty, !conversationId.isEmpty else { break }
            if let model, case .ready(let service) = model.phase {
                Task { await service.sendMessage(text, in: conversationId) }
            } else {
                // App was terminated; queue via ShareBridge for pick-up on next launch.
                ShareBridge.writePendingShare(PendingShare(
                    conversationId: conversationId, text: text,
                    imageData: nil, imageUTI: nil, fileData: nil, filename: nil
                ))
            }
        case "RELAY_MARK_READ":
            guard !conversationId.isEmpty, let model, case .ready(let service) = model.phase else { break }
            service.markConversationRead(conversationId)
        default:
            // Default action = notification tap → open conversation.
            if !conversationId.isEmpty {
                if let model {
                    model.pendingNotificationConversationId = conversationId
                } else {
                    coldStartConversationId = conversationId
                }
            }
        }
        completionHandler()
    }

    // Deliver notifications even when the app is in the foreground (e.g. a message
    // arrives while a different conversation is open). The banner lets the user tap
    // to navigate without leaving the app first. A banner for the conversation the
    // user is already looking at is suppressed — the message is right there.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let conversationId = notification.request.content.userInfo["conversationId"] as? String ?? ""
        if !conversationId.isEmpty,
           let model, case .ready(let service) = model.phase,
           service.activeConversationId == conversationId,
           UIApplication.shared.applicationState == .active {
            completionHandler([])
            return
        }
        completionHandler([.banner, .sound, .badge])
    }

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
        NSLog("Relay: remote notification registration failed: \(error)")
    }
}
