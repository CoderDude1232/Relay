//
//  AppSwitcherPrivacy.swift
//  Relay
//
//  What the app-switcher snapshot hides: everything (a full-screen blur), only
//  what's private (messages, names and photos, blurred where they are), or
//  nothing. Settings → Security → App Switcher.
//

import SwiftUI
import UIKit

@MainActor @Observable
final class AppSwitcherPrivacy {
    static let shared = AppSwitcherPrivacy()

    enum Mode: String, CaseIterable, Identifiable {
        case everything, content, off
        var id: String { rawValue }
        var title: String {
            switch self {
            case .everything: "Hide Everything"
            case .content: "Hide Messages & Names"
            case .off: "Don't Hide"
            }
        }
    }

    static let modeKey = "relay.appSwitcherPrivacy"

    static var mode: Mode {
        Mode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .content
    }

    /// True while the app is leaving the screen in `.content` mode.
    private(set) var hidingContent = false

    /// Blurs the marked views and draws them now: the snapshot is taken as soon
    /// as the app resigns active, before SwiftUI's next frame.
    func hide() {
        hidingContent = true
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                window.rootViewController?.view.setNeedsLayout()
                window.layoutIfNeeded()
            }
        }
        CATransaction.flush()
    }

    func show() {
        hidingContent = false
    }
}

private struct AppSwitcherBlur: ViewModifier {
    func body(content: Content) -> some View {
        let hidden = AppSwitcherPrivacy.shared.hidingContent
        content
            .blur(radius: hidden ? 16 : 0, opaque: false)
            .transaction { $0.animation = nil }
    }
}

extension View {
    /// Blurred in the app switcher when the user hides messages and names.
    func hiddenInAppSwitcher() -> some View {
        modifier(AppSwitcherBlur())
    }
}
