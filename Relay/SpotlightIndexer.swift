//
//  SpotlightIndexer.swift
//  Relay
//

import CoreSpotlight
import SecureStorage
import UIKit

enum SpotlightIndexer {
    private static let domain = "app.relaymsg.conversations"

    /// Precomputed, Sendable input for one conversation. The caller builds these
    /// cheaply on the main actor (dictionary lookups + cached avatar bytes); the
    /// expensive image decode/re-encode happens in `index`, off the main thread.
    struct IndexItem: Sendable {
        let id: String
        let name: String
        let avatarData: Data?
    }

    /// Builds and submits Spotlight items. `nonisolated` so it can run on a
    /// background task — image decoding here previously ran on the main thread
    /// during every conversation refresh and caused UI hitches.
    nonisolated static func index(_ items: [IndexItem]) {
        let searchable: [CSSearchableItem] = items.map { item in
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
        CSSearchableIndex.default().indexSearchableItems(searchable) { _ in }
    }

    static func deindexAll() {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in }
    }
}
