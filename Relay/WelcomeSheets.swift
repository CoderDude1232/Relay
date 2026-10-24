//
//  WelcomeSheets.swift
//  Relay
//
//  "What's New" after an update, and the notification explanation shown
//  before the system prompt (plus the chat-list row when they're off).
//

import Observation
import SwiftUI
import UIKit
import UserNotifications

// MARK: - What's New

enum WhatsNew {
    /// Bump when the highlights below change.
    static let version = 1
    private static let seenKey = "relay.whatsNewSeen"

    struct Item: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    static let items: [Item] = [
        Item(symbol: "mic.fill", title: "Hold to Record",
             detail: "Hold the microphone to record, slide left to cancel or up to keep going, and listen back before sending."),
        Item(symbol: "eye.slash", title: "Spoilers",
             detail: "Hide part of a message until it's tapped. Use the Spoiler button in the formatting bar."),
        Item(symbol: "moon.fill", title: "Focus Filters",
             detail: "Choose which chats show and notify during a Focus in Settings > Focus."),
        Item(symbol: "bolt.fill", title: "Shortcuts and Control Center",
             detail: "Send messages, start calls and open chats from Shortcuts, Siri and Control Center."),
        Item(symbol: "lock.shield.fill", title: "Stronger Account Password",
             detail: "With an account password set, your email alone can't take over an account that's in use."),
    ]

    /// True once after an update with new highlights. A fresh install starts
    /// with them marked seen (see `markSeen`).
    static var shouldShow: Bool {
        guard let seen = UserDefaults.standard.object(forKey: seenKey) as? Int else { return false }
        return seen < version
    }

    /// Records that this version's highlights were shown (or don't apply).
    static func markSeen() {
        UserDefaults.standard.set(version, forKey: seenKey)
    }

    /// For people who used Relay before What's New existed: show it once.
    static func noteExistingUser() {
        if UserDefaults.standard.object(forKey: seenKey) == nil {
            UserDefaults.standard.set(0, forKey: seenKey)
        }
    }
}

struct WhatsNewSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    Text("What's New in Relay")
                        .font(.largeTitle.bold())
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                        .padding(.top, 36)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(WhatsNew.items) { item in
                        HStack(alignment: .top, spacing: 16) {
                            Image(systemName: item.symbol)
                                .font(.title2)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 40)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.headline)
                                Text(item.detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
            }
            Button {
                dismiss()
            } label: {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .onDisappear { WhatsNew.markSeen() }
    }
}

// MARK: - Notifications

/// Whether notifications are on, refreshed when the app comes forward.
@Observable
final class NotificationPermission {
    static let shared = NotificationPermission()
    private(set) var status: UNAuthorizationStatus = .authorized
    /// "Not Now" on the explanation this session: no chat-list nag until next launch.
    var deferredThisSession = false

    private init() { refresh() }

    func refresh() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in self.status = status }
        }
    }

    var isOff: Bool { status == .denied || status == .notDetermined }

    /// Asks the system (first time), or opens Settings once it was declined.
    func turnOn(using appDelegate: AppDelegate?) {
        if status == .denied {
            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                UIApplication.shared.open(url)
            }
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            Task { @MainActor in
                if granted { UIApplication.shared.registerForRemoteNotifications() }
                self.refresh()
            }
        }
    }
}

/// Shown after sign-in instead of the bare system prompt.
struct NotificationPrimerSheet: View {
    let onTurnOn: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 20)
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 52))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            Text("Never Miss a Message")
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text("Turn on notifications to know when someone messages or calls you. Previews stay private: you choose in Settings whether they show names or message text.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
            Spacer(minLength: 20)
            Button {
                dismiss()
                onTurnOn()
            } label: {
                Text("Turn On Notifications")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            Button("Not Now") {
                NotificationPermission.shared.deferredThisSession = true
                dismiss()
            }
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .presentationDetents([.medium, .large])
    }
}
