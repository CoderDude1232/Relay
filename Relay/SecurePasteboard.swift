//
//  SecurePasteboard.swift
//  Relay
//
//  Every copy out of Relay is local-only (never synced to the user's other
//  devices through Universal Clipboard). Secrets additionally expire.
//

import UIKit

enum SecurePasteboard {
    /// Copies ordinary text (message text, account id, add-link): local only.
    static func copy(_ text: String) {
        UIPasteboard.general.setItems(
            [[UIPasteboard.typeAutomatic: text]],
            options: [.localOnly: true]
        )
    }

    /// Copies a secret (e.g. the recovery key): local only, and cleared from
    /// the pasteboard automatically after `lifetime`.
    static func copySecret(_ text: String, lifetime: TimeInterval = 120) {
        UIPasteboard.general.setItems(
            [[UIPasteboard.typeAutomatic: text]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(lifetime),
            ]
        )
    }
}
