//
//  MessagingService+ShareBridge.swift
//  Relay
//
//  Messages queued by the Share Extension.
//  Split out of MessagingService.swift.
//

import CryptoCore
import CryptoKit
import Foundation
import Intents
import LibSignalClient
import Network
import Observation
import UniformTypeIdentifiers
import RelayCore
import RelayKit
import SwiftProtobuf
import SecureStorage
import UIKit
import UserNotifications
import os

extension MessagingService {
    // MARK: - Share Extension bridge

    // Unencrypted list in App Group storage so the Share Extension can show a
    // picker without the database keys.
    func updateShareConversationList() {
        let summaries = conversations.filter { !$0.archived }.map { conv -> ShareConversationSummary in
            let name: String
            if let gid = conv.groupId {
                name = displayName(forAccount: gid)
            } else {
                name = displayName(forAccount: conv.peerAccount)
            }
            return ShareConversationSummary(
                id: conv.id,
                displayName: name,
                initials: ShareBridge.makeInitials(name),
                isGroup: conv.groupId != nil
            )
        }
        ShareBridge.writeConversations(summaries)
        for conv in conversations {
            if let data = peerAvatarData(forAccount: conv.peerAccount) {
                ShareBridge.writeAvatar(data, forConversationId: conv.id)
            }
        }
    }

    // Sends every PendingShare left by the Share Extension, Siri or a quick
    // reply, oldest first, and returns the last one's conversation id for
    // navigation.
    func processPendingShare() async -> String? {
        var lastConversationId: String?
        for share in ShareBridge.readAndClearPendingShares() {
            lastConversationId = await sendPendingShare(share)
        }
        return lastConversationId
    }

    private func sendPendingShare(_ share: PendingShare) async -> String {
        let conversationId = share.conversationId
        if let text = share.text, !text.isEmpty {
            await sendMessage(text, in: conversationId)
        } else if let imageData = share.imageData {
            // Shared photos carry the original file's EXIF/GPS; re-encode.
            guard let clean = MediaSanitizer.photo(imageData) else {
                postRelayNotice("Couldn't send the shared photo.")
                return conversationId
            }
            let attachment = PendingAttachment(
                data: clean.data, contentType: clean.contentType, filename: nil,
                width: clean.width, height: clean.height
            )
            await sendMessage("", in: conversationId, attachments: [attachment])
        } else if let fileData = share.fileData, let name = share.filename {
            let type = UTType(filenameExtension: (name as NSString).pathExtension)
            let ct = type?.preferredMIMEType ?? "application/octet-stream"
            var data = fileData
            if let type, type.conforms(to: .quickTimeMovie) || type.conforms(to: .mpeg4Movie) {
                // A shared video loses its location metadata like a picked one.
                // (Other formats, which AVFoundation can't rewrite, go as files.)
                guard let clean = await MediaSanitizer.video(fileData, contentType: ct) else {
                    postRelayNotice("Couldn't send the shared video.")
                    return conversationId
                }
                data = clean
            }
            let attachment = PendingAttachment(
                data: data, contentType: ct, filename: name, width: 0, height: 0
            )
            await sendMessage("", in: conversationId, attachments: [attachment])
        }
        return conversationId
    }

    // Feeds share-sheet and Siri suggestions.
    func donateInteraction(peerAccount account: String, conversationId: String) {
        // Siri's store is outside the encrypted DB: only when the user opted
        // in, and never for panic-hidden chats.
        guard PrivacyPreferences.shareSuggestionsEnabled,
              !PanicModeManager.hiddenConversationIdsSnapshot().contains(conversationId) else { return }
        let name = displayName(forAccount: account)
        // Identify the person by conversation id, not account id: these
        // donations live in Siri's store, outside the app.
        let handle = INPersonHandle(value: conversationId, type: .unknown)
        let avatarImage = peerAvatarData(forAccount: account).flatMap { INImage(imageData: $0) }
        let person = INPerson(
            personHandle: handle,
            nameComponents: nil,
            displayName: name,
            image: avatarImage,
            contactIdentifier: nil,
            customIdentifier: conversationId
        )
        let intent = INSendMessageIntent(
            recipients: [person],
            outgoingMessageType: .outgoingMessageText,
            content: nil,
            speakableGroupName: nil,
            conversationIdentifier: conversationId,
            serviceName: "Relay",
            sender: nil,
            attachments: nil
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing
        interaction.groupIdentifier = conversationId
        interaction.donate { _ in }
    }
}
