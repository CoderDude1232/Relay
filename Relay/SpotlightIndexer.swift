//
//  SpotlightIndexer.swift
//  Relay
//
//  Spotlight indexing of conversation names is OPT-IN (Settings → Privacy →
//  "Show Chats in Search", default off): the system search index lives outside
//  Relay's encrypted store. Hidden (panic-mode) conversations are never indexed,
//  and `deindexAll()` removes everything Relay ever put in the index.
//

import CoreSpotlight
import SecureStorage
import UIKit

enum SpotlightIndexer {
    nonisolated private static let domain = "app.relaymsg.conversations"

    /// Precomputed, Sendable input for one conversation. The caller builds these
    /// cheaply on the main actor (dictionary lookups + cached avatar bytes); the
    /// expensive image decode/re-encode happens in `index`, off the main thread.
    struct IndexItem: Sendable {
        let id: String
        let name: String
        let avatarData: Data?
    }

    nonisolated static var isEnabled: Bool { PrivacyPreferences.spotlightIndexingEnabled }

    /// Builds and submits Spotlight items. `nonisolated` so it can run on a
    /// background task. A no-op unless the user opted in; hidden conversations
    /// are filtered out (and removed if they were indexed before being hidden).
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

    /// Removes this conversation from the index (e.g. it was just hidden or deleted).
    nonisolated static func deindex(conversationId: String) {
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [conversationId]) { _ in }
    }

    /// Removes every Relay item from Spotlight. Call from every wipe / sign-out /
    /// panic path, and when the user turns indexing off.
    nonisolated static func deindexAll() {
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in }
        // Belt and braces: items indexed by older builds without a domain.
        index.deleteAllSearchableItems { _ in }
    }
}
