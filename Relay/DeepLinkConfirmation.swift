//
//  DeepLinkConfirmation.swift
//  Relay
//
//  Links that change who you talk to (group invites, contact invites, username
//  links) never act on their own: the user always sees what the link does and
//  confirms it first. Links are also held until the app lock (if enabled) has
//  been unlocked.
//

import SwiftUI

/// What an invite link resolved to, shown to the user before joining.
/// Produced by `MessagingService.previewGroupInvite(token:fragment:)` and
/// consumed by `MessagingService.acceptGroupInvite(_:)`.
struct GroupInvitePreview: Identifiable {
    let id = UUID()
    let groupName: String
    let memberCount: Int
    /// The decrypted invite payload (JSON), opaque to the UI.
    let payload: Data
    /// Set when we're already in this group: the link just opens it.
    var existingConversationId: String? = nil
}

/// A link action awaiting the user's confirmation.
enum PendingLinkAction: Identifiable {
    case username(String)
    case contactInvite(token: String)
    case groupInvite(GroupInvitePreview)
    case callLink(callId: String, host: String, secret: String)

    var id: String {
        switch self {
        case .username(let name): return "u:\(name)"
        case .contactInvite(let token): return "c:\(token)"
        case .groupInvite(let preview): return "g:\(preview.id.uuidString)"
        case .callLink(let callId, _, _): return "call:\(callId)"
        }
    }
}

extension EnvironmentValues {
    /// True while the app-lock screen is covering the UI. Deep links wait for it.
    @Entry var relayAppLocked: Bool = false
}

struct LinkConfirmationSheet: View {
    let action: PendingLinkAction
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 44, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .padding(.top, 28)

            VStack(spacing: 8) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Button(action: onConfirm) {
                    Text(confirmTitle)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Cancel", role: .cancel, action: onCancel)
                    .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(false)
    }

    private var icon: String {
        switch action {
        case .username, .contactInvite: return "person.crop.circle.badge.plus"
        case .groupInvite: return "person.3.fill"
        case .callLink: return "phone.badge.waveform.fill"
        }
    }

    private var title: String {
        switch action {
        case .username(let name): return "Message @\(name)?"
        case .contactInvite: return "Add contact?"
        case .groupInvite(let preview): return "Join “\(preview.groupName)”?"
        case .callLink: return "Join this call?"
        }
    }

    private var message: String {
        switch action {
        case .username:
            return "You opened a link to a Relay username. Start a conversation with this person?"
        case .contactInvite:
            return "Someone shared a one-time Relay contact link with you. Adding them starts a conversation and lets you message each other."
        case .groupInvite(let preview):
            let count = preview.memberCount == 1 ? "1 member" : "\(preview.memberCount) members"
            return "This group has \(count). Everyone in it will be able to see your name, profile, and the messages you send to the group."
        case .callLink:
            return "You'll ask the person who shared this link to let you in. Everyone in the call will see your name."
        }
    }

    private var confirmTitle: String {
        switch action {
        case .username: return "Start Conversation"
        case .contactInvite: return "Add Contact"
        case .groupInvite: return "Join Group"
        case .callLink: return "Ask to Join"
        }
    }
}
