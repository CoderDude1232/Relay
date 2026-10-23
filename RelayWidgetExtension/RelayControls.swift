//
//  RelayControls.swift
//  RelayWidgetExtension
//
//  Control Center / Lock Screen / Action button controls: Scan QR Code, New
//  Message, Note to Self, and Panic Mode, which re-hides the chats marked hidden without opening Relay.
//

import AppIntents
import Foundation
import SwiftUI
import WidgetKit

struct ScanQRControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.relaymsg.control.scan") {
            ControlWidgetButton(action: OpenURLIntent(URL(string: "relay://scan")!)) {
                Label("Scan QR Code", systemImage: "qrcode.viewfinder")
            }
        }
        .displayName("Scan QR Code")
        .description("Open Relay's scanner to add someone.")
    }
}

struct NewMessageControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.relaymsg.control.compose") {
            ControlWidgetButton(action: OpenURLIntent(URL(string: "relay://compose")!)) {
                Label("New Message", systemImage: "square.and.pencil")
            }
        }
        .displayName("New Message")
        .description("Start a new chat in Relay.")
    }
}

struct NoteToSelfControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.relaymsg.control.note") {
            ControlWidgetButton(action: OpenURLIntent(URL(string: "relay://note-to-self")!)) {
                Label("Note to Self", systemImage: "note.text")
            }
        }
        .displayName("Note to Self")
        .description("Open your Note to Self chat in Relay.")
    }
}

struct PanicModeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.relaymsg.control.panic") {
            ControlWidgetButton(action: PanicLockIntent()) {
                Label("Panic Mode", systemImage: "eye.slash.fill")
            }
        }
        .displayName("Panic Mode")
        .description("Hide your hidden chats in Relay right away.")
    }
}

struct PanicLockIntent: AppIntent {
    static let title: LocalizedStringResource = "Hide Hidden Chats"
    static let description = IntentDescription("Re-hides the chats you've marked hidden in Relay.")
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        PanicLockSignal.send()
        return .result()
    }
}

/// How the control reaches Relay: a timestamp in the App Group (checked when
/// Relay next comes forward) and a Darwin notification (if it's running now).
enum PanicLockSignal {
    static let defaultsKey = "panic.lockRequestedAt"
    static let darwinName = "app.relaymsg.panic-lock" as CFString

    static func send() {
        UserDefaults(suiteName: "group.app.relaymsg")?.set(Date().timeIntervalSince1970, forKey: defaultsKey)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(darwinName), nil, nil, true
        )
    }
}
