//
//  SpotlightIndexer.swift
//  Relay
//

import CoreSpotlight
import SecureStorage
import UIKit

enum SpotlightIndexer {
    private static let domain = "com.morgandaly.RelayMessenger.conversations"

    static func index(
        conversations: [Conversation],
        displayName: (String) -> String,
        avatarData: (String) -> Data?
    ) {
        let items: [CSSearchableItem] = conversations.map { conv in
            let account = conv.groupId ?? conv.peerAccount
            let name = conv.groupId.map { displayName($0) } ?? displayName(conv.peerAccount)
            let attrs = CSSearchableItemAttributeSet(contentType: .contact)
            attrs.displayName = name
            attrs.contentDescription = "Relay"
            if let data = avatarData(account),
               let thumb = UIImage(data: data)?.jpegData(compressionQuality: 0.6) {
                attrs.thumbnailData = thumb
            }
            return CSSearchableItem(
                uniqueIdentifier: conv.id,
                domainIdentifier: domain,
                attributeSet: attrs
            )
        }
        CSSearchableIndex.default().indexSearchableItems(items) { _ in }
    }

    static func deindexAll() {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in }
    }
}
