//
//  GrowthPrompts.swift
//  Relay
//
//  When to ask for an App Store rating, and the invite card for people who
//  haven't got many chats yet. Counts stay on this device.
//

import Foundation
import SwiftUI

enum ReviewPrompt {
    private static let firstUseKey = "relay.firstUseAt"
    private static let sentKey = "relay.sentMessageCount"
    private static let goodCallsKey = "relay.goodCallCount"
    private static let askedVersionKey = "relay.reviewAskedVersion"
    private static let askedAtKey = "relay.reviewAskedAt"

    private static var defaults: UserDefaults { .standard }

    /// The first day Relay was used with an account.
    static func noteFirstUse() {
        if defaults.object(forKey: firstUseKey) == nil {
            defaults.set(Date().timeIntervalSince1970, forKey: firstUseKey)
        }
    }

    static func noteMessageSent() {
        defaults.set(defaults.integer(forKey: sentKey) + 1, forKey: sentKey)
    }

    /// A call that connected and lasted a while.
    static func noteGoodCall() {
        defaults.set(defaults.integer(forKey: goodCallsKey) + 1, forKey: goodCallsKey)
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// Someone who's clearly using Relay: a few days in, plenty of messages
    /// or a couple of good calls, not asked in this version or recently.
    /// iOS also limits the prompt to three times a year.
    static var shouldAsk: Bool {
        let firstUse = defaults.double(forKey: firstUseKey)
        guard firstUse > 0, Date().timeIntervalSince1970 - firstUse > 4 * 86400 else { return false }
        guard defaults.integer(forKey: sentKey) >= 20 || defaults.integer(forKey: goodCallsKey) >= 2 else { return false }
        guard defaults.string(forKey: askedVersionKey) != appVersion else { return false }
        let askedAt = defaults.double(forKey: askedAtKey)
        return askedAt == 0 || Date().timeIntervalSince1970 - askedAt > 120 * 86400
    }

    static func noteAsked() {
        defaults.set(appVersion, forKey: askedVersionKey)
        defaults.set(Date().timeIntervalSince1970, forKey: askedAtKey)
    }
}

enum InviteCard {
    static let dismissedKey = "relay.inviteCardDismissed"
}

/// "Relay is better with friends", for accounts with few chats.
struct InviteFriendsCard: View {
    let onInvite: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.2.wave.2.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Relay is better with friends").font(.subheadline.weight(.semibold))
                Text("Send your link to the people you talk to most. They can message you the moment they join.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Invite Friends", action: onInvite)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderless)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.10), in: .rect(cornerRadius: 16, style: .continuous))
    }
}
