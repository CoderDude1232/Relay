//
//  SecurePasteboard.swift
//  Relay
//
//  Copies out of Relay are local-only (no Universal Clipboard). Secrets also
//  expire.
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
