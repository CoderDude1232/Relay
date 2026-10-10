//
//  GroupViews.swift
//  Relay
//
//  Group creation + management UI. The relay holds the roster; these views
//  drive MessagingService, which handles sender-key setup and rotation.
//

import PhotosUI
import RelayKit
import SecureStorage
import SwiftUI

/// Name a new group and pick members — from existing 1:1 chats and/or by
/// typing usernames. Creates it client-side (see MessagingService.createGroup).
struct NewGroupView: View {
    let service: MessagingService
    let onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var members: [String] = [""]
    /// Peer accounts picked from existing 1:1 chats.
    @State private var pickedAccounts: Set<String> = []
    @State private var creating = false
    @State private var error: String?

    /// 1:1 chats whose peer has a known username (createGroup resolves members
    /// by username), excluding Note to Self, the official Relay chat and
    /// blocked contacts.
    private struct ChatCandidate: Identifiable {
        let account: String
        let username: String
        let name: String
        var id: String { account }
    }

    private var chatCandidates: [ChatCandidate] {
        var seen = Set<String>()
        return service.conversations.compactMap { c in
            guard !c.isGroup,
                  c.peerAccount != service.noteToSelfAccount,
                  c.peerAccount != service.relayOfficialAccount,
                  !service.isBlocked(c.peerAccount),
                  seen.insert(c.peerAccount).inserted,
                  let username = service.username(forAccount: c.peerAccount),
                  !username.isEmpty
            else { return nil }
            return ChatCandidate(
                account: c.peerAccount,
                username: username,
                name: service.displayName(forAccount: c.peerAccount)
            )
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Group name") {
                    TextField("Name", text: $name).incognitoKeyboard()
                }
                let candidates = chatCandidates
                if !candidates.isEmpty {
                    Section {
                        ForEach(candidates) { candidate in
                            let picked = pickedAccounts.contains(candidate.account)
                            Button {
                                if picked {
                                    pickedAccounts.remove(candidate.account)
                                } else {
                                    pickedAccounts.insert(candidate.account)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    AvatarView(
                                        name: candidate.name,
                                        size: 32,
                                        imageData: service.peerAvatarData(forAccount: candidate.account)
                                    )
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(candidate.name).foregroundStyle(.primary)
                                        Text("@\(candidate.username)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(picked ? Color.accentColor : Color.secondary)
                                        .font(.title3)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
                        }
                    } header: {
                        Text("From your chats")
                    } footer: {
                        if !pickedAccounts.isEmpty {
                            Text("\(pickedAccounts.count) selected")
                        }
                    }
                }
                Section("Add by username") {
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

    private var typedUsernames: [String] {
        members
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && (!typedUsernames.isEmpty || !pickedAccounts.isEmpty)
    }

    private func create() {
        let typed = typedUsernames
        let candidates = chatCandidates
        let picked = candidates
            .filter { pickedAccounts.contains($0.account) }
            .map { $0.username }
        creating = true
        error = nil
        Task {
            defer { creating = false }
            // Resolve typed usernames individually first so a typo can be
            // named instead of failing the whole group with a generic error.
            var missing: [String] = []
            for username in typed {
                do {
                    _ = try await service.resolveAccount(username: username)
                } catch RelayAPIError.http(status: 404, _) {
                    missing.append(username)
                } catch {
                    self.error = "Couldn't create the group: \(error.localizedDescription)"
                    return
                }
            }
            if !missing.isEmpty {
                let list = missing.map { "@\($0)" }.joined(separator: ", ")
                self.error = missing.count == 1
                    ? "\(list) isn't on Relay. Check the username and try again."
                    : "These usernames aren't on Relay: \(list). Check them and try again."
                return
            }
            var seen = Set<String>()
            let usernames = (picked + typed).filter { seen.insert($0.lowercased()).inserted }
            do {
                let conversationId = try await service.createGroup(
                    name: name.trimmingCharacters(in: .whitespaces),
                    memberUsernames: usernames
                )
                dismiss()
                onCreated(conversationId)
            } catch {
                self.error = "Couldn't create the group: \(error.localizedDescription)"
            }
        }
    }
}

/// Shows a group's info: avatar, description, name, members, invite link.
struct GroupInfoView: View {
    let service: MessagingService
    let conversationId: String
    let ownAccountId: String

    @Environment(\.dismiss) private var dismiss
    @State private var newMember = ""
    @State private var editingName = false
    @State private var draftName = ""
    @State private var editingDescription = false
    @State private var draftDescription = ""
    @State private var inviteURL: String?
    @State private var showingShareSheet = false
    @State private var showingAvatarPicker = false
    @State private var working = false
    @State private var errorMessage: String?
    @State private var addMemberError: String?
    @State private var descriptionExpanded = false
    @State private var confirmLeave = false
    /// Member being reported (abuse reporting for group content, App Review 1.2).
    @State private var reportTarget: ReportTarget?

    private struct ReportTarget: Identifiable {
        let account: String
        var id: String { account }
    }
    @State private var memberToRemove: String?

    private var group: StoredGroup? { service.group(for: conversationId) }

    /// Mirrors MessagingService.requireGroupAdmin: legacy groups with no
    /// recorded admins are open to every member.
    private var isAdmin: Bool {
        guard let group else { return false }
        return MessagingService.isGroupAdmin(ownAccountId, in: group)
    }

    private var conversation: Conversation? {
        service.conversations.first { $0.id == conversationId }
    }

    var body: some View {
        NavigationStack {
            List {
                if let group {
                    // Avatar + name header
                    Section {
                        HStack(spacing: 16) {
                            if isAdmin {
                                Button {
                                    showingAvatarPicker = true
                                } label: {
                                    GroupAvatarView(data: group.avatarData, name: group.name, size: 64)
                                        .overlay(alignment: .bottomTrailing) {
                                            AvatarEditBadge(systemImage: "pencil", diameter: 24)
                                                .offset(x: 4, y: 4)
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Change group photo")
                            } else {
                                GroupAvatarView(data: group.avatarData, name: group.name, size: 64)
                                    .accessibilityHidden(true)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.name)
                                    .font(.headline)
                                Text("\(group.members.count) members")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if isAdmin {
                                Button {
                                    draftName = group.name
                                    editingName = true
                                } label: {
                                    Image(systemName: "pencil")
                                        .foregroundStyle(.blue)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Rename group")
                            }
                        }
                        .padding(.vertical, 4)
                    } footer: {
                        if !isAdmin {
                            Text("Only admins can change group info.")
                        }
                    }

                    // Description
                    Section("Description") {
                        if group.description.isEmpty {
                            if isAdmin {
                                Button("Add a description…") {
                                    draftDescription = ""
                                    editingDescription = true
                                }
                                .foregroundStyle(.secondary)
                            } else {
                                Text("No description")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .top) {
                                    Text(group.description)
                                        .foregroundStyle(.primary)
                                        .lineLimit(descriptionExpanded ? nil : 3)
                                    Spacer()
                                    if isAdmin {
                                        Button {
                                            draftDescription = group.description
                                            editingDescription = true
                                        } label: {
                                            Image(systemName: "pencil")
                                                .foregroundStyle(.blue)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Edit description")
                                    }
                                }
                                if group.description.count > 80 {
                                    Button(descriptionExpanded ? "Read Less" : "Read More") {
                                        withAnimation { descriptionExpanded.toggle() }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                                }
                            }
                        }
                    }

                    // Invite link (admin-only; not on demo accounts)
                    if isAdmin && !service.isDemoAccount {
                        Section("Invite") {
                            Button {
                                run {
                                    let url = try await service.createGroupInviteLink(groupId: group.id)
                                    await MainActor.run {
                                        inviteURL = url
                                        showingShareSheet = true
                                    }
                                }
                            } label: {
                                Label("Create Invite Link", systemImage: "link.badge.plus")
                            }
                        }
                    }

                    // Per-chat settings: mute, disappearing messages, Face ID lock…
                    Section("Chat") {
                        Toggle(isOn: Binding(
                            get: { service.isConversationMuted(conversationId) },
                            set: { service.setConversationMuted(conversationId, muted: $0) }
                        )) {
                            Label("Mute Notifications", systemImage: "bell.slash")
                        }
                        if let conversation {
                            NavigationLink {
                                ChatPrivacySettingsView(service: service, conversation: conversation)
                            } label: {
                                Label("Chat Settings", systemImage: "gearshape")
                            }
                        }
                    }

                    // Announce-only (admin-only setting)
                    if group.admins.contains(ownAccountId) || group.isAnnounceOnly {
                        Section("Permissions") {
                            Toggle("Announce Only", isOn: Binding(
                                get: { group.isAnnounceOnly },
                                set: { newVal in run { try await service.setAnnounceOnly(newVal, in: group.id) } }
                            ))
                            .disabled(!group.admins.contains(ownAccountId))
                        }
                    }

                    // Members
                    Section("Members (\(group.members.count))") {
                        ForEach(group.members, id: \.self) { member in
                            let memberIsAdmin = group.admins.contains(member)
                            HStack(spacing: 12) {
                                AvatarView(
                                    name: service.displayName(forAccount: member),
                                    size: 36,
                                    imageData: service.peerAvatarData(forAccount: member)
                                )
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        Text(service.displayName(forAccount: member))
                                        if memberIsAdmin {
                                            Image(systemName: "crown.fill")
                                                .font(.caption)
                                                .foregroundStyle(.yellow)
                                        }
                                    }
                                    if member == ownAccountId {
                                        Text("You")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                // Gated on the VIEWER being an admin.
                                if isAdmin && member != ownAccountId {
                                    Button(role: .destructive) {
                                        memberToRemove = member
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Remove \(service.displayName(forAccount: member))")
                                }
                            }
                            .contextMenu {
                                if isAdmin && member != ownAccountId {
                                    if memberIsAdmin {
                                        Button(role: .destructive) {
                                            run { try await service.demoteAdmin(in: group.id, account: member) }
                                        } label: {
                                            Label("Remove Admin", systemImage: "crown.slash")
                                        }
                                    } else {
                                        Button {
                                            run { try await service.promoteAdmin(in: group.id, account: member) }
                                        } label: {
                                            Label("Make Admin", systemImage: "crown")
                                        }
                                    }
                                    Divider()
                                    Button(role: .destructive) {
                                        memberToRemove = member
                                    } label: {
                                        Label("Remove from Group", systemImage: "person.badge.minus")
                                    }
                                }
                                if member != ownAccountId {
                                    Button(role: .destructive) {
                                        reportTarget = ReportTarget(account: member)
                                    } label: {
                                        Label("Report…", systemImage: "exclamationmark.bubble")
                                    }
                                }
                            }
                        }
                    }

                    if isAdmin {
                    Section("Add member") {
                        HStack {
                            TextField("Username", text: $newMember)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .submitLabel(.done)
                                .onSubmit {
                                    let username = newMember.trimmingCharacters(in: .whitespaces)
                                    guard !username.isEmpty else { return }
                                    addMember(username: username, groupId: group.id)
                                }
                            Button("Add") {
                                let username = newMember.trimmingCharacters(in: .whitespaces)
                                addMember(username: username, groupId: group.id)
                            }
                            .disabled(newMember.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        if let addMemberError {
                            Label(addMemberError, systemImage: "exclamationmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    } // end admin-only add member

                    Section {
                        // Reports the group's admins (who run it); individual
                        // members can be reported from their row's menu.
                        if let admin = group.admins.first(where: { $0 != ownAccountId }) {
                            Button("Report Group", role: .destructive) {
                                reportTarget = ReportTarget(account: admin)
                            }
                        }
                        Button("Leave Group", role: .destructive) {
                            confirmLeave = true
                        }
                    } footer: {
                        Text("Long-press a member to report them. Reports go to the Relay team; messages are included only if you choose.")
                    }

                    if let errorMessage {
                        Section {
                            Text(errorMessage)
                                .foregroundStyle(.red)
                                .font(.footnote)
                        }
                    }
                } else {
                    Text("Group not available.")
                }
            }
            .navigationTitle("Group Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay { if working { ProgressView() } }
            // Rename alert
            .alert("Rename Group", isPresented: $editingName) {
                TextField("Name", text: $draftName).incognitoKeyboard()
                Button("Save") {
                    guard let group else { return }
                    let name = draftName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    run { try await service.renameGroup(groupId: group.id, name: name) }
                }
                Button("Cancel", role: .cancel) {}
            }
            // Description alert
            .alert("Group Description", isPresented: $editingDescription) {
                TextField("Description", text: $draftDescription).incognitoKeyboard()
                Button("Save") {
                    guard let group else { return }
                    run { try await service.setGroupDescription(draftDescription, groupId: group.id) }
                }
                Button("Cancel", role: .cancel) {}
            }
            // Avatar picker
            .sheet(item: $reportTarget) { target in
                ReportContactSheet(
                    service: service, account: target.account,
                    displayName: service.displayName(forAccount: target.account)
                )
            }
            .sheet(isPresented: $showingAvatarPicker) {
                if let group {
                    GroupAvatarPickerSheet(service: service, groupId: group.id)
                }
            }
            // Share sheet for invite link
            .sheet(isPresented: $showingShareSheet) {
                if let url = inviteURL {
                    ShareSheet(items: [url])
                }
            }
            // Leave group confirmation
            .confirmationDialog("Leave this group?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Leave Group", role: .destructive) {
                    run(dismissAfter: true) { try await service.leaveGroup(group?.id ?? "") }
                }
            }
            // Remove member confirmation
            .confirmationDialog(
                "Remove \(memberToRemove.flatMap { service.displayName(forAccount: $0) }.map { "\($0) from the group?" } ?? "member from the group?")",
                isPresented: Binding(get: { memberToRemove != nil }, set: { if !$0 { memberToRemove = nil } }),
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    if let m = memberToRemove, let gid = group?.id {
                        run { try await service.removeGroupMember(m, fromGroup: gid) }
                    }
                    memberToRemove = nil
                }
            }
        }
    }

    private func addMember(username: String, groupId: String) {
        guard !username.isEmpty else { return }
        newMember = ""
        addMemberError = nil
        working = true
        Task {
            do {
                try await service.addGroupMember(username: username, toGroup: groupId)
            } catch {
                addMemberError = "Couldn't add \"\(username)\": \(error.localizedDescription)"
            }
            working = false
        }
    }

    private func run(dismissAfter: Bool = false, _ action: @escaping () async throws -> Void) {
        working = true
        errorMessage = nil
        Task {
            do {
                try await action()
            } catch {
                errorMessage = error.localizedDescription
            }
            working = false
            // Only dismiss when the action actually succeeded — on failure the
            // error stays visible in the sheet.
            if dismissAfter && errorMessage == nil { dismiss() }
        }
    }
}

// MARK: - Group avatar display

struct GroupAvatarView: View {
    let data: Data?
    let name: String
    let size: CGFloat

    var body: some View {
        if let data, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(.circle)
        } else {
            Circle()
                .fill(.quaternary)
                .frame(width: size, height: size)
                .overlay {
                    Text(name.prefix(2).uppercased())
                        .font(.system(size: size * 0.35, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
        }
    }
}

// MARK: - Avatar picker sheet

private struct GroupAvatarPickerSheet: View {
    let service: MessagingService
    let groupId: String

    @Environment(\.dismiss) private var dismiss
    @State private var selectedItem: PhotosPickerItem?
    @State private var working = false
    @State private var uploadError: String?

    var body: some View {
        NavigationStack {
            PhotosPicker(
                selection: $selectedItem,
                matching: .images,
                photoLibrary: .shared()
            ) {
                ContentUnavailableView("Pick a photo", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Group Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: selectedItem) { _, item in
                guard let item else { return }
                working = true
                uploadError = nil
                Task {
                    do {
                        guard let data = try? await item.loadTransferable(type: Data.self) else {
                            throw URLError(.cannotDecodeContentData)
                        }
                        try await service.setGroupAvatar(data, groupId: groupId)
                        dismiss()
                    } catch {
                        uploadError = error.localizedDescription
                    }
                    working = false
                }
            }
            .overlay { if working { ProgressView() } }
            .alert("Photo Upload Failed", isPresented: Binding(
                get: { uploadError != nil },
                set: { if !$0 { uploadError = nil } }
            )) {
                Button("OK", role: .cancel) { uploadError = nil }
            } message: {
                Text(uploadError ?? "")
            }
        }
    }
}

