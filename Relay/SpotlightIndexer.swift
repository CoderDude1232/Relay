//
//  SpotlightIndexer.swift
//  Relay
//
//  Spotlight indexing of conversation names is opt-in ("Show Chats in Search",
//  off by default) because the system index lives outside the encrypted store.
//  Hidden conversations are never indexed.
//

import CoreSpotlight
import SecureStorage
import UIKit

enum SpotlightIndexer {
    nonisolated private static let domain = "app.relaymsg.conversations"

    /// Sendable input for one conversation, built cheaply on the main actor.
    /// The image decode/re-encode happens in `index`, off the main thread.
    struct IndexItem: Sendable {
        let id: String
        let name: String
        let avatarData: Data?
    }

    nonisolated static var isEnabled: Bool { PrivacyPreferences.spotlightIndexingEnabled }

    /// Builds and submits Spotlight items. No-op unless the user opted in;
    /// hidden conversations are skipped and removed if previously indexed.
    nonisolated static func index(_ items: [IndexItem]) {
        guard isEnabled else { return }
        let hidden = PanicModeManager.hiddenConversationIdsSnapshot()
        let visible = items.filter { !hidden.contains($0.id) }
        let searchable: [CSSearchableItem] = visible.map { item in
            let attrs = CSSearchableItemAttributeSet(contentType: .contact)
            attrs.displayName = item.name
            attrs.contentDescription = "Relay"
            if let data = item.avatarData,
               let thumb = UIImage(data: data)?.jpegData(compressionQuality: 0.6) {
                attrs.thumbnailData = thumb
            }
            return CSSearchableItem(
                uniqueIdentifier: item.id,
                domainIdentifier: domain,
                attributeSet: attrs
            )
        }
        let index = CSSearchableIndex.default()
        if !hidden.isEmpty {
            index.deleteSearchableItems(withIdentifiers: Array(hidden)) { _ in }
        }
        guard !searchable.isEmpty else { return }
        index.indexSearchableItems(searchable) { _ in }
    }

    /// Removes this conversation from the index (e.g. hidden or deleted).
    nonisolated static func deindex(conversationId: String) {
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [conversationId]) { _ in }
    }

    /// Removes every Relay item from Spotlight. Call on every wipe, sign-out and
    /// panic path, and when the user turns indexing off.
    nonisolated static func deindexAll() {
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in }
        // Items indexed by older builds have no domain.
        index.deleteAllSearchableItems { _ in }
    }
}
