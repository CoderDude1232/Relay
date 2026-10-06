//
//  PrivacyPreferences.swift
//  Relay
//
//  Central list of privacy-related user preferences: keys and their
//  privacy-preserving defaults. Values that an extension must also read live
//  in the App Group suite; app-only values live in UserDefaults.standard.
//

import Foundation

/// Lock-screen / banner preview level. Stored in the App Group suite because
/// the Notification Service Extension applies it.
nonisolated enum NotificationPreviewSetting: String, CaseIterable, Sendable {
    case full
    case nameOnly
    case none

    static let key = "relay.notificationPrivacy"
    static let appGroupId = "group.app.relaymsg"

    /// Default for anyone who has never picked a level: sender name only, no
    /// message content on the lock screen.
    static let defaultValue: NotificationPreviewSetting = .nameOnly

    static var current: NotificationPreviewSetting {
        let raw = UserDefaults(suiteName: appGroupId)?.string(forKey: key)
        return raw.flatMap(NotificationPreviewSetting.init(rawValue:)) ?? defaultValue
    }

    static func set(_ value: NotificationPreviewSetting) {
        UserDefaults(suiteName: appGroupId)?.set(value.rawValue, forKey: key)
    }

    var showsSenderName: Bool { self != .none }
    var showsContent: Bool { self == .full }
}

/// App-only privacy toggles (UserDefaults.standard).
nonisolated enum PrivacyPreferences {
    /// Index conversation names in Spotlight. Default OFF (opt-in).
    static let spotlightIndexingKey = "relay.spotlightIndexing"
    /// Fetch link previews for links you send. Default ON (incoming previews are
    /// never fetched automatically regardless of this toggle).
    static let linkPreviewsKey = "relay.linkPreviews"
    /// Send typing indicators. Default ON. The service gates sending on this key.
    static let sendTypingKey = "relay.sendTyping"
    /// Ask the keyboard not to learn/store what you type. Default ON.
    static let incognitoKeyboardKey = "privacy.incognitoKeyboard"
    /// The user explicitly agreed to contact discovery (address-book matching).
    static let contactDiscoveryConsentKey = "relay.contactDiscoveryConsent"

    private static var defaults: UserDefaults { .standard }

    static var spotlightIndexingEnabled: Bool {
        defaults.bool(forKey: spotlightIndexingKey)
    }

    static var linkPreviewsEnabled: Bool {
        defaults.object(forKey: linkPreviewsKey) as? Bool ?? true
    }

    static var sendTypingEnabled: Bool {
        defaults.object(forKey: sendTypingKey) as? Bool ?? true
    }

    static var incognitoKeyboardEnabled: Bool {
        defaults.object(forKey: incognitoKeyboardKey) as? Bool ?? true
    }

    static var contactDiscoveryConsented: Bool {
        defaults.bool(forKey: contactDiscoveryConsentKey)
    }
}

/// Contact discovery (address-book matching) never runs on its own: only when
/// the user taps "Find contacts on Relay" after reading this explanation.
nonisolated enum ContactDiscoveryConsent {
    static let explanation = "Relay will read the email addresses in your contacts and check which of them belong to Relay accounts. The addresses are blinded on your device before the check, and your address book is never stored on Relay's servers. This only happens when you tap Find Contacts."

    static var isGranted: Bool { PrivacyPreferences.contactDiscoveryConsented }

    static func grant() {
        UserDefaults.standard.set(true, forKey: PrivacyPreferences.contactDiscoveryConsentKey)
    }

    static func revoke() {
        UserDefaults.standard.removeObject(forKey: PrivacyPreferences.contactDiscoveryConsentKey)
    }
}
