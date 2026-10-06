//
//  MessagingService+RelayNotices.swift
//  Relay
//
//  Account-activity notices posted to the official, read-only Relay chat.
//  They are local to the device where the event happened (device link/unlink
//  notices reach every device because the relay announces those).
//

import Foundation

extension MessagingService {
    func noteAccountCreated(username: String) {
        postRelayNotice("Your account @\(username) was created on this device. Your messages are end-to-end encrypted — not even Relay can read them.")
    }

    func noteSignedIn(username: String) {
        postRelayNotice("You signed in to @\(username) on this device. Your other devices were told a new device joined. If this wasn't you, unlink it in Settings → Linked Devices.")
    }

    func noteAccountRecovered(username: String) {
        postRelayNotice("Your account @\(username) was recovered on this device with your email and account password. If this wasn't you, review Settings → Linked Devices now.")
    }

    func noteUsernameChanged(from old: String?, to new: String) {
        if let old, !old.isEmpty, old != new {
            postRelayNotice("Your username changed from @\(old) to @\(new). Links and QR codes with @\(old) no longer work, and someone else could claim it.")
        } else {
            postRelayNotice("Your username is now @\(new).")
        }
    }

    func noteBackupRestored(from date: Date?) {
        if let date {
            postRelayNotice("Your messages were restored from the iCloud backup made \(date.formatted(date: .abbreviated, time: .shortened)).")
        } else {
            postRelayNotice("Your messages were restored from your iCloud backup.")
        }
    }

    func noteFirstBackup() {
        postRelayNotice("Your first encrypted iCloud backup is complete. Keep your Recovery Key safe — without it the backup can't be restored.")
    }

    func noteBackupFailing(_ reason: String) {
        postRelayNotice("iCloud backup failed: \(reason) Relay will keep trying.")
    }
}
