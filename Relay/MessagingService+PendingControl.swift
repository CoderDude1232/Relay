//
//  MessagingService+PendingControl.swift
//  Relay
//
//  Applies control payloads the Notification Service Extension decrypted while
//  the app was backgrounded (see RelayCore/PendingControl.swift). The NSE has
//  already claimed those envelopes and advanced the ratchet, so the app would
//  otherwise treat them as duplicates and silently lose group changes,
//  profiles, delivery receipts and in-chat notices.
//

import Foundation
import RelayCore
import RelayKit
import SecureStorage

extension MessagingService {
    /// Guards against overlapping drains (the connection loop and the queue
    /// drain can both trigger one across await points).
    private static var isDrainingPendingControl = false

    /// Replays NSE-persisted control payloads through the same handlers
    /// `handleEnvelope` uses, oldest first. Each row is removed before it is
    /// applied, so a payload is applied at most once.
    ///
    /// - Parameter sendReceipts: delivery receipts need a live socket; pass
    ///   `false` before the WebSocket is up and they stay queued for the next
    ///   drain (everything else is applied immediately).
    func drainPendingControlMessages(sendReceipts: Bool = true) async {
        guard !Self.isDrainingPendingControl else { return }
        Self.isDrainingPendingControl = true
        defer { Self.isDrainingPendingControl = false }

        let pending = PendingControlStore.load(from: storage)
        guard !pending.isEmpty else { return }

        // Batch delivery receipts per (peer, group) like a single receipt message.
        struct ReceiptTarget: Hashable { let peer: String; let groupId: String? }
        var receipts: [ReceiptTarget: [Int64]] = [:]
        var receiptOrder: [ReceiptTarget] = []

        for entry in pending {
            if case .deliveryReceipt = entry.item, !sendReceipts { continue }
            PendingControlStore.remove(entry.key, from: storage)

            switch entry.item {
            case .deliveryReceipt(let peer, let conversationId, let timestamp):
                let target = ReceiptTarget(peer: peer, groupId: conversationId.flatMap { group(for: $0)?.id })
                if receipts[target] == nil { receiptOrder.append(target) }
                receipts[target, default: []].append(timestamp)
            case .backfillUsername:
                break // legacy item; usernames now arrive in the sender certificate
            case .notepad(let conversationId, let content):
                setNotepadContent(content, for: conversationId)
            case .groupUpdate(let info, let sender):
                await handleGroupUpdate(info, authenticatedSender: sender)
            case .profile(let profile):
                await applyPeerProfile(profile)
            case .screenshotAlert(let shot):
                let name = displayName(forAccount: shot.senderAccount)
                insertSystemLine("\(name) took a screenshot", conversationId: shot.conversationId)
            case .screenSecurity(let upd):
                try? storage.messages.setConversationPeerScreenSecurity(upd.conversationId, enabled: upd.enabled)
            case .callLinkRequest(let callId, let account, let secret, let receivedAt):
                // Stale requests: the person has long stopped waiting.
                guard Date().timeIntervalSince(receivedAt) < 10 * 60 else { break }
                await onCallMessage?(CallInfo(
                    callId: callId, type: .linkJoinRequest, sdp: secret, ice: "",
                    callerAccount: account, groupId: "link:" + callId
                ))
            }
        }

        for target in receiptOrder {
            guard let timestamps = receipts[target], !timestamps.isEmpty else { continue }
            await sendReceipt(.delivery, timestamps: timestamps, toPeer: target.peer, groupId: target.groupId)
        }
        refreshConversations()
    }
}
