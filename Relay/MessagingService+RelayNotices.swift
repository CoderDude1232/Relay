//
//  MessagingService+RelayNotices.swift
//  Relay
//
//  Account-activity notices posted to the official, read-only Relay chat.
//  Most are local to the device where the event happened; device link/unlink
//  and sign-in changes (noteAccountChange) reach every device because the
//  relay announces those.
//

import Foundation

extension MessagingService {
    /// The relay's AccountNotice: how the account signs in changed, on another
    /// of its devices.
    func noteAccountChange(kind: String, timeMs: Int64) {
        let what: String
        switch kind {
        case "passkey_added": what = "A passkey was added to your account"
        case "passkey_removed": what = "A passkey was removed from your account"
        case "recovery_key_set": what = "A new recovery key was made for your account"
        case "recovery_key_removed": what = "Your account's recovery key was turned off"
        case "account_password_set": what = "Your account password was changed"
        case "email_removed": what = "The email address was removed from your account"
        case "email_changed": what = "Your account's email address was changed"
        default: what = "How your account signs in was changed"
        }
        let when = Date(timeIntervalSince1970: TimeInterval(timeMs) / 1000)
            .formatted(date: .abbreviated, time: .shortened)
        postRelayNotice("\(what) from another of your devices (\(when)). If this wasn't you, someone has access to one of your devices: remove it in Profile → Linked Devices, then check your passkeys, recovery key and account password.")
    }

    func noteAccountCreated(username: String) {
        postRelayNotice("Your account @\(username) was created on this device. Your messages are end-to-end encrypted — not even Relay can read them.")
    }

    func noteSignedIn(username: String) {
        postRelayNotice("You signed in to @\(username) on this device. Any other devices signed in to this account were signed out — to use Relay on more than one device, add them with Link Device. If this wasn't you, sign out of your email account everywhere and change its password.")
    }

    func noteAccountRecovered(username: String) {
        postRelayNotice("Your account @\(username) was recovered on this device with your email and account password. Your other devices were signed out. If this wasn't you, someone knows your email and account password — recover your account again from your own device right away.")
    }

    func noteUsernameChanged(from old: String?, to new: String) {
        if let old, !old.isEmpty, old != new {
            postRelayNotice("Your username changed from @\(old) to @\(new). Links and QR codes with @\(old) no longer work, and someone else could claim it.")
        } else {
            postRelayNotice("Your username is now @\(new).")
        }
    }
}
