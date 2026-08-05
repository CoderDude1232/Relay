//
//  ContactCardView.swift
//  Relay
//
//  A contact-info sheet for a 1:1 peer: avatar, display name, underlying
//  username, and an editable custom display name (nickname). Also the entry
//  point to safety-number verification. The nickname is a local override —
//  it never leaves the device and takes precedence over the username
//  everywhere the peer's name is shown.
//

import SecureStorage
import SwiftUI

struct ContactCardView: View {
    let service: MessagingService
    let conversationId: String

    @Environment(\.dismiss) private var dismiss
    @State private var nickname = ""
    @State private var showingVerification = false

    private var conversation: Conversation? {
        service.conversations.first { $0.id == conversationId }
    }
    private var account: String { conversation?.peerAccount ?? "" }
    private var displayName: String { service.displayName(forAccount: account) }
    private var username: String? { service.username(forAccount: account) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        AvatarView(name: displayName, size: 72, imageData: service.peerAvatarData(forAccount: account))
                        Text(displayName).font(.title2.bold())
                        if let username {
                            Text("@\(username)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                Section("Name") {
                    TextField("Custom name", text: $nickname)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(save)
                    if !nickname.isEmpty {
                        Button("Clear custom name", role: .destructive) {
                            nickname = ""
                            save()
                        }
                    }
                }

                Section("Security") {
                    Button {
                        showingVerification = true
                    } label: {
                        Label("Verify Safety Number", systemImage: "checkmark.shield")
                    }
                    .tint(.primary)
                }

                Section("Account") {
                    LabeledContent("Account ID") {
                        Text(account)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .navigationTitle("Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save(); dismiss() }
                }
            }
            .onAppear { nickname = service.nickname(forAccount: account) ?? "" }
            .sheet(isPresented: $showingVerification) {
                VerificationView(service: service, conversationId: conversationId, peerName: displayName)
            }
        }
    }

    private func save() {
        service.setNickname(nickname, forAccount: account)
    }
}
