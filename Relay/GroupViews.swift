//
//  GroupViews.swift
//  Relay
//
//  Group creation + management UI. The relay holds the roster; these views
//  drive MessagingService, which handles sender-key setup and rotation.
//

import SecureStorage
import SwiftUI

/// Name a new group and list member usernames; creates it on the relay.
struct NewGroupView: View {
    let service: MessagingService
    let onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var members: [String] = [""]
    @State private var creating = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Group name") {
                    TextField("Name", text: $name)
                }
                Section("Members (usernames)") {
                    ForEach(members.indices, id: \.self) { index in
                        TextField("Username", text: $members[index])
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    Button("Add another") { members.append("") }
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(!canCreate || creating)
                }
            }
            .overlay { if creating { ProgressView() } }
        }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && members.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func create() {
        let usernames = members
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        creating = true
        error = nil
        Task {
            do {
                let conversationId = try await service.createGroup(
                    name: name.trimmingCharacters(in: .whitespaces),
                    memberUsernames: usernames
                )
                dismiss()
                onCreated(conversationId)
            } catch {
                self.error = "Couldn't create the group. Check the usernames and try again."
            }
            creating = false
        }
    }
}

/// Shows a group's members with add / remove / leave controls.
struct GroupInfoView: View {
    let service: MessagingService
    let conversationId: String
    let ownAccountId: String

    @Environment(\.dismiss) private var dismiss
    @State private var newMember = ""
    @State private var working = false

    private var group: StoredGroup? { service.group(for: conversationId) }

    var body: some View {
        NavigationStack {
            List {
                if let group {
                    Section("Members (\(group.members.count))") {
                        ForEach(group.members, id: \.self) { member in
                            HStack {
                                Text(member == ownAccountId ? "You" : String(member.prefix(8)))
                                Spacer()
                                if member != ownAccountId {
                                    Button(role: .destructive) {
                                        run { try await service.removeGroupMember(member, fromGroup: group.id) }
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                    Section("Add member") {
                        HStack {
                            TextField("Username", text: $newMember)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            Button("Add") {
                                let username = newMember.trimmingCharacters(in: .whitespaces)
                                newMember = ""
                                run { try await service.addGroupMember(username: username, toGroup: group.id) }
                            }
                            .disabled(newMember.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    Section {
                        Button("Leave Group", role: .destructive) {
                            run(dismissAfter: true) { try await service.leaveGroup(group.id) }
                        }
                    }
                } else {
                    Text("Group not available.")
                }
            }
            .navigationTitle(group?.name ?? "Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay { if working { ProgressView() } }
        }
    }

    private func run(dismissAfter: Bool = false, _ action: @escaping () async throws -> Void) {
        working = true
        Task {
            try? await action()
            working = false
            if dismissAfter { dismiss() }
        }
    }
}
