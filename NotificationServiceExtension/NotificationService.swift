//
//  NotificationService.swift
//  NotificationServiceExtension
//
//  Decrypts the pushed envelope (carried in the APNs payload as base64) using
//  the SAME shared EnvelopeProcessor the app uses, then fills the banner with
//  the real sender + preview. Apple only ever saw ciphertext; decryption
//  happens here, on-device, against the App-Group SQLCipher store.
//

import CryptoCore
import RelayCore
import RelayKit
import SecureStorage
import UserNotifications

class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent)
        bestAttemptContent = content

        guard let content else {
            contentHandler(request.content)
            return
        }

        // Decrypt best-effort; on any failure we still deliver the generic
        // "New message" placeholder rather than dropping the notification.
        if let decrypted = try? decrypt(request) {
            content.title = decrypted.title
            content.body = decrypted.body
        }
        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }

    private struct Preview {
        let title: String
        let body: String
    }

    private func decrypt(_ request: UNNotificationRequest) throws -> Preview? {
        guard
            let encoded = request.content.userInfo["e"] as? String,
            let data = Data(base64Encoded: encoded),
            let envelope = IncomingEnvelope(serializedEnvelope: data)
        else { return nil }

        let appGroupId = RelayStore.appGroupId
        let storage = try RelayStore.open(appGroupId: appGroupId)
        guard let account = try RelayStore.loadAccount(appGroupId: appGroupId) else { return nil }
        let engine = try storage.makeCryptoEngine(accountId: account.accountId, deviceId: account.deviceId)

        let processor = EnvelopeProcessor(storage: storage, engine: engine)
        let result = try processor.process(envelope)
        guard let notification = result.notification else { return nil }

        let title = displayName(for: notification.conversationId, in: storage)
            ?? String(notification.senderAccount.prefix(8))
        return Preview(title: title, body: notification.body)
    }

    private func displayName(for conversationId: String, in storage: SecureStore) -> String? {
        let username = try? storage.database.query(
            "SELECT peer_username FROM conversations WHERE id = ?", [.text(conversationId)]
        ).first?.first?.string
        return username ?? nil
    }
}
