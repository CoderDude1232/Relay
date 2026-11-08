//
//  MessageReminders.swift
//  Relay
//
//  "Remind Me" on a message: a local notification on this device that opens
//  the chat. Nothing goes to the relay. What the banner shows follows the
//  lock-screen preview setting, since iOS keeps scheduled notifications
//  outside Relay's encryption.
//

import Foundation
import UserNotifications

nonisolated enum MessageReminders {
    enum When: CaseIterable, Identifiable {
        case oneHour, threeHours, tonight, tomorrow

        var id: Self { self }

        var label: String {
            switch self {
            case .oneHour: "In 1 Hour"
            case .threeHours: "In 3 Hours"
            case .tonight: "Tonight (8 PM)"
            case .tomorrow: "Tomorrow (9 AM)"
            }
        }

        /// Nil when it doesn't apply now (tonight, once it's past 8 PM).
        func date(from now: Date = Date(), calendar: Calendar = .current) -> Date? {
            switch self {
            case .oneHour: return now.addingTimeInterval(3600)
            case .threeHours: return now.addingTimeInterval(3 * 3600)
            case .tonight:
                guard let eight = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: now), eight > now
                else { return nil }
                return eight
            case .tomorrow:
                guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
                return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
            }
        }
    }

    static func schedule(at date: Date, conversationId: String, messageId: String,
                         senderName: String, text: String) async -> Bool {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true else { return false }
        let preview = NotificationPreviewSetting.current
        let content = UNMutableNotificationContent()
        content.title = preview.showsSenderName ? "Reminder: \(senderName)" : "Reminder"
        let snippet = text.trimmingCharacters(in: .whitespacesAndNewlines)
        content.body = preview.showsContent && !snippet.isEmpty
            ? String(snippet.prefix(180))
            : "You asked to be reminded about a message."
        content.sound = .default
        // Opens the chat, like a message notification.
        content.userInfo = ["conversationId": conversationId]
        content.threadIdentifier = conversationId
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let request = UNNotificationRequest(
            identifier: "reminder-\(messageId)-\(Int(date.timeIntervalSince1970))",
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        )
        return (try? await center.add(request)) != nil
    }
}
