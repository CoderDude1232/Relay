//
//  MessagingService+PendingControl.swift
//  Relay
//
//  Applies control payloads the NSE decrypted in the background (see
//  RelayCore/PendingControl.swift). The NSE has already claimed those envelopes
//  and advanced the ratchet, so without this the app would drop them as
//  duplicates.
//

import Foundation
import RelayCore
import RelayKit
import SecureStorage

extension MessagingService {
    /// The connection loop and the queue drain can both start a drain across
    /// await points.
    private static var isDrainingPendingControl = false

    /// Replays NSE-persisted payloads through `handleEnvelope`'s handlers,
    /// oldest first. Rows are removed before being applied (at most once).
    ///
    /// - Parameter sendReceipts: pass `false` before the WebSocket is up;
    ///   delivery receipts then stay queued for the next drain.
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
                break // usernames arrive in the sender certificate
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
