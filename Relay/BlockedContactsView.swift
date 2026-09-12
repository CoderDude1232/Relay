//
//  BlockedContactsView.swift
//  Relay
//

import SwiftUI

struct BlockedContactsView: View {
    let service: MessagingService

    @State private var accountToUnblock: String?

    private var blocked: [String] {
        service.blockedAccounts.sorted()
    }

    var body: some View {
        Group {
            if blocked.isEmpty {
                ContentUnavailableView(
                    "No Blocked Contacts",
                    systemImage: "person.crop.circle.badge.minus",
                    description: Text("Accounts you block won't be able to message you.")
                )
            } else {
                List {
                    ForEach(blocked, id: \.self) { account in
                        HStack(spacing: 12) {
                            AvatarView(
                                name: service.displayName(forAccount: account),
                                size: 36,
                                imageData: service.peerAvatarData(forAccount: account)
                            )
                            Text(service.displayName(forAccount: account))
                                .font(.body)
                            Spacer(minLength: 0)
                            Button("Unblock") {
                                accountToUnblock = account
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.red)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Blocked")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Unblock \(accountToUnblock.flatMap { service.displayName(forAccount: $0) } ?? "this contact")?",
            isPresented: Binding(get: { accountToUnblock != nil }, set: { if !$0 { accountToUnblock = nil } }),
            titleVisibility: .visible
        ) {
            Button("Unblock") {
                if let a = accountToUnblock { service.unblockAccount(a) }
                accountToUnblock = nil
            }
            Button("Cancel", role: .cancel) { accountToUnblock = nil }
        } message: {
            Text("They will be able to send you messages again.")
        }
    }
}
