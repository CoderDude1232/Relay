//
//  RelayApp.swift
//  Relay
//
//  Created by Ethan Daly on 18/7/2026.
//

import BackgroundTasks
import CoreSpotlight
import Intents
import OSLog
import RelayCore
import RelayKit
import SecureStorage
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
                // AppDelegate owns the CallManager so it exists before a VoIP
                // push can arrive on a killed-app launch.
                .environment(appDelegate.callManager)
                .task {
                    #if DEBUG
                    PrivacyRedactor.runSelfCheck()
                    #endif
                    // Spotlight indexing is opt-in; clear anything left in the index.
                    if !SpotlightIndexer.isEnabled { SpotlightIndexer.deindexAll() }
                    // Decrypted media left behind by a killed session.
                    TempMediaFiles.sweep()
                    appDelegate.model = model
                    // A notification tap may have arrived before the model was wired.
                    if let id = appDelegate.coldStartConversationId {
                        model.pendingNotificationConversationId = id
                        appDelegate.coldStartConversationId = nil
                    }
                    await model.boot()
                    if model.isReady {
                        wireCallManager()
                        // Only ask for notification permission once there is an
                        // account, never over the Welcome screen. For existing
                        // users this just re-registers for remote notifications.
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
                        // relay://contact/<token> (one-time contact invite)
                        let token = url.pathComponents.dropFirst().first ?? ""
                        guard !token.isEmpty else { return }
                        model.pendingContactInviteToken = token
                    } else if url.host == "call" {
                        // relay://call/<callId>#<hostAccount>.<secret>
                        if let link = CallManager.parseCallLink(url) { model.pendingCallLink = link }
                    } else if url.host == "proxy" {
                        // relay://proxy/<host[:port]>
                        model.pendingProxy = RelayProxy.parse(url.absoluteString)
                    } else if url.host == "scan" {
                        // relay://scan, from the Scan QR Code control.
                        model.pendingScanQR = true
                    } else if url.host == "conversation" {
                        // relay://conversation/<conversationId> (widget tap)
                        let convId = url.pathComponents.dropFirst().first ?? ""
                        guard !convId.isEmpty else { return }
                        model.pendingNotificationConversationId = convId
                    } else if url.host == "pending-share" {
                        // relay://pending-share, opened by the Share Extension after
                        // it writes a PendingShare to the App Group container.
                        guard case .ready(let service) = model.phase else { return }
                        Task {
                            if let convId = await service.processPendingShare() {
                                model.pendingNotificationConversationId = convId
                            }
                        }
                    }
                }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    guard let convId = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                          !convId.isEmpty else { return }
                    model.pendingNotificationConversationId = convId
                }
                .onContinueUserActivity(NSStringFromClass(INSendMessageIntent.self)) { _ in
                    // Siri "send via Relay"; enterForeground has already processed the share.
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
                    // https://relaymsg.app/proxy#<host[:port]>
                    if let url = activity.webpageURL, url.host == "relaymsg.app", url.path.hasPrefix("/proxy") {
                        model.pendingProxy = RelayProxy.parse(url.absoluteString)
                        return
                    }
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
                    } else if kind == "call" {
                        // https://relaymsg.app/call/<callId>#<hostAccount>.<secret>
                        if let link = CallManager.parseCallLink(url) { model.pendingCallLink = link }
                    } else if kind == "g" {
                        // https://relaymsg.app/g/<token>#<fragment-key> (encrypted group invite)
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
                        // Refresh the iCloud backup, at most daily unless something changed.
                        if case .ready(let service) = model.phase {
                            Task { await CloudBackupManager.shared.backupIfDue(service: service) }
                        }
                    case .active:
                        PanicModeManager.shared.applyControlLockIfRequested()
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
        callManager.callLinkSecretResolver = { callId in CallLinkStore.shared.link(callId)?.secret }
        callManager.callLinkNameResolver = { callId in CallLinkStore.shared.link(callId)?.name }
        callManager.groupMembersResolver = { groupId in
            // Only groups we're still in and have accepted: a group we left, or
            // one a stranger added us to, can't ring us.
            guard let conv = service.conversations.first(where: { $0.groupId == groupId }), !conv.isRequest,
                  let members = service.group(for: conv.id)?.members,
                  members.contains(service.credentials.accountId)
            else { return nil }
            return members
        }
        callManager.isCallAllowed = { account in
            service.isCallAllowed(from: account)
        }
        callManager.isHiddenPeer = { account in
            guard let convId = service.conversations.first(where: { !$0.isGroup && $0.peerAccount == account })?.id else { return false }
            return PanicModeManager.shared.isHidden(convId)
        }
        callManager.onCallFromRequest = { account in
            service.noteCallFromRequest(account)
        }
        callManager.onAwaitingCallOffer = {
            // A VoIP push woke us for an anonymous call: bring the socket up and
            // replay any OFFER the NSE already decrypted, so the caller can be
            // identified within the wait window.
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
            await MainActor.run { appModel.signOut(removeFromServer: false, remoteWipe: true) }
        }
        service.onRemovedFromAccount = {
            await MainActor.run { appModel.handleRemovedFromAccount() }
        }
        callManager.onFetchTurnCredentials = { afterFailure in
            try await service.apiClient.fetchTurnCredentials(afterFailure: afterFailure)
        }
        Task { await replayPendingCallOffersDuringWake(service) }
        appDelegate.pushKitDelegate.wire(apiClient: service.apiClient)
    }

    /// Replays call signals the NSE took off the queue: for 10 s after a wake,
    /// then for as long as a call is still being set up (up to a minute), since
    /// the caller's ICE candidates keep arriving after the OFFER.
    private func replayPendingCallOffersDuringWake(_ service: MessagingService) async {
        let callManager = appDelegate.callManager
        for tick in 0..<120 {
            await service.replayPendingCallOffers()
            if tick >= 20 {
                switch callManager.state {
                case .incoming, .outgoing, .connecting: break
                default: if !callManager.isInGroupCall { return }
                }
                if case .active = callManager.state { return }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}

/// Owns the CallManager and PushKitDelegate for the life of the process, so they
/// exist before any view renders or a VoIP push arrives on a killed-app launch.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let bgRefreshTaskId = "app.relaymsg.bg-refresh"
    private static let log = Logger(subsystem: "app.relaymsg", category: "AppDelegate")

    let callManager = CallManager()
    let pushKitDelegate = PushKitDelegate()
    weak var model: AppModel?

    /// Siri/CarPlay "send a message", handled in the app so it sends immediately.
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        intent is INSendMessageIntent ? SiriSendHandler(appDelegate: self) : nil
    }
    /// Notification tap that arrived before the model was wired (cold start).
    var coldStartConversationId: String?

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.bgRefreshTaskId)
        // A floor only; iOS picks the actual time.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Drains Siri-queued messages when the socket is closed. Must be
        // registered before launch finishes.
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
        WatchBridge.shared.activate(appDelegate: self)
        PanicModeManager.shared.observeControlLock()
        UNUserNotificationCenter.current().delegate = self
        // Both actions act on the account without opening the app, so require
        // an unlocked device; otherwise anyone holding a locked phone could reply.
        let replyAction = UNTextInputNotificationAction(
            identifier: "RELAY_QUICK_REPLY",
            title: "Reply",
            options: [.authenticationRequired],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Message"
        )
        let markReadAction = UNNotificationAction(
            identifier: "RELAY_MARK_READ",
            title: "Mark as Read",
            options: [.authenticationRequired]
        )
        let msgCategory = UNNotificationCategory(
            identifier: "RELAY_MESSAGE",
            actions: [replyAction, markReadAction],
            intentIdentifiers: [NSStringFromClass(INSendMessageIntent.self)],
            options: [.allowInCarPlay]
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
            // Also used by Apple Watch and CarPlay. If iOS just launched the app
            // in the background for this, wait briefly for startup and send now
            // rather than queueing until the next launch.
            let text = (response as? UNTextInputNotificationResponse)?.userText ?? ""
            guard !text.isEmpty, !conversationId.isEmpty else { break }
            let task = UIApplication.shared.beginBackgroundTask(withName: "relay.quickReply")
            Task { @MainActor in
                defer { UIApplication.shared.endBackgroundTask(task) }
                for _ in 0..<40 {
                    if let model = self.model, case .ready = model.phase { break }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                if let model = self.model, case .ready(let service) = model.phase {
                    await service.sendMessage(text, in: conversationId)
                } else {
                    // Still not up (e.g. storage locked): send on next launch.
                    ShareBridge.writePendingShare(PendingShare(
                        conversationId: conversationId, text: text,
                        imageData: nil, imageUTI: nil, fileData: nil, filename: nil
                    ))
                }
            }
        case "RELAY_MARK_READ":
            guard !conversationId.isEmpty, let model, case .ready(let service) = model.phase else { break }
            service.markConversationRead(conversationId)
        default:
            // Notification tap: open the conversation.
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

    // Show banners in the foreground too, except for the conversation already on screen.
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
        Self.log.error("remote notification registration failed: \(PrivacyRedactor.error(error))")
    }
}
